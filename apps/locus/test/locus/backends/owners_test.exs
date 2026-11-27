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
  version; the bound on sessions, the oldest ended one forgotten; the
  memory the box and each athanor admit, reserved before an open's
  preparation and released once a session's process is gone, a spawn the
  keeper refused after making it among them, at the keeper's release, and
  held through the loss of the keeper's channel; idleness
  and leases through a driven sweep; kept homes shared by the sessions of
  one entry, held to their bound, reset and retired; renew, release,
  reconcile and status. Sessions run through the test environment's
  `Locus.DirectLauncher`; the pool and the kept homes the owners read are
  a stub the test sets, which keeps its homes through the same launcher.
  """

  use ExUnit.Case, async: false

  import Prima.Test.Wait

  alias Locus.Backends.{Backend, LeaseSweeper, Owners, Reservations}
  alias Prima.LocusBackends

  @athanor "ath_owners"
  @idle "exec cat >/dev/null"
  @home "vlt_01a09fee-2c3d-7e4f-8a5b-6c7d8e9f0a1b"

  defmodule HostsLauncher do
    @moduledoc false
    # A session launcher that tells its server each spec it is asked to
    # start and refuses it as its server's code says, as cyfr-locus refuses
    # a spawn whose hosts resolve to nothing or whose egress its guard does
    # not confirm.
    def spawn({test, code}, spec) do
      send(test, {:spec, spec})
      {:error, {:refused, code}}
    end

    # It starts nothing, so it holds nothing to fence or adopt.
    def fence(_server, _tag), do: :none
    def adopt(_server, _ledger, _heir), do: {:ok, []}
    def place(_server, _id, _whose, _owner), do: {:ok, nil}
    def drop(_server, _id), do: :ok
  end

  defmodule BeforeSpawn do
    @moduledoc false
    # A session launcher that tells its test the session process about to
    # ask for its process, and holds that process there; its fence is out
    # of reach until the test's clock has moved past where it started, and
    # then finds nothing held, since it never starts anything.
    def spawn({test, _clock, _start}, _spec) do
      send(test, {:before_spawn, self()})

      receive do
        :go -> {:error, {:refused, "unavailable"}}
      end
    end

    def fence({_test, clock, start}, _tag) do
      if Agent.get(clock, & &1) > start,
        do: :none,
        else: {:error, {:launcher_unavailable, :timeout}}
    end

    def adopt(_server, _ledger, _heir), do: {:ok, []}
    def place(_server, _id, _whose, _owner), do: {:ok, nil}
    def drop(_server, _id), do: :ok
  end

  defmodule AdoptionRace do
    @moduledoc false
    # A session launcher whose first adoption is unanswered and whose next
    # one names a process the test chose, its answer held until the test
    # lets it go; its fence finds nothing held, since it starts nothing.
    def adopt({test, counter}, ledger, heir) do
      case Agent.get_and_update(counter, fn n -> {n, n + 1} end) do
        0 ->
          {:error, {:launcher_unavailable, :timeout}}

        _ ->
          tag = %{
            ledger: ledger,
            session: {make_ref(), "ss_adopted"},
            athanor: "ath_owners",
            memory_bytes: 402_653_184,
            home_id: nil
          }

          send(test, {:adoption_snapshot, self(), heir, tag})

          receive do
            :go -> {:ok, [tag]}
          end
      end
    end

    def fence(_server, _tag), do: :none
    def place(_server, _id, _whose, _owner), do: {:ok, nil}
    def drop(_server, _id), do: :ok
  end

  defmodule Stub do
    @moduledoc false
    # The pool a test sets (an answer, or `:hang` for a launcher that
    # never answers) and kept homes under the test's root, through the
    # direct launcher.
    def pool_stats(agent, "backends") do
      case Agent.get(agent, & &1.pool) do
        :hang ->
          Process.sleep(:infinity)

        # Each read told to the test and answered when it says so.
        {:held, test, answer} ->
          send(test, {:pool_read, self()})

          receive do
            :answer -> answer
          end

        answer ->
          answer
      end
    end

    # A making the test holds waits here, before anything of the home is made.
    def home_ensure(agent, id) do
      if test = Agent.get_and_update(agent, &Map.pop(&1, :before_ensure)) do
        send(test, {:home_about_to_be_created, self()})

        receive do
          :continue_ensure -> :ok
        end
      end

      Locus.DirectLauncher.home_ensure(root(agent), id)
    end

    # A measure the test makes fail stands for one the keeper could not
    # take over the whole home.
    def home_measure(agent, id) do
      case Agent.get(agent, &Map.get(&1, :measure)) do
        :fail -> {:error, {:refused, "internal"}}
        _ -> Locus.DirectLauncher.home_measure(root(agent), id)
      end
    end

    def home_list(agent) do
      held(agent, :home_list)
      Locus.DirectLauncher.home_list(root(agent))
    end

    def home_reset(agent, id), do: home_change(agent, :home_reset, id)
    def home_retire(agent, id), do: home_change(agent, :home_retire, id)

    # A change the test answers stands for one the keeper refused.
    defp home_change(agent, op, id) do
      held(agent, op)

      case Agent.get(agent, &Map.get(&1, :home_change)) do
        nil -> apply(Locus.DirectLauncher, op, [root(agent), id])
        answer -> answer
      end
    end

    # A list or a change the test holds waits here, told to the test, until
    # it says go: a launcher slow to answer.
    defp held(agent, op) do
      if test = Agent.get(agent, &Map.get(&1, :home_held)) do
        send(test, {:home_held, op, self()})

        receive do
          :go -> :ok
        end
      end
    end

    defp root(agent), do: [kept_root: Agent.get(agent, & &1.kept_root)]
  end

  defmodule OldTags do
    @moduledoc false
    # The direct launcher, but for its adoption, which names a process it
    # holds under a tag a table wrote before tags named a row and a key.
    import Kernel, except: [send: 2]

    @old %{
      ledger: nil,
      session: {:before, "ss_before"},
      athanor: "ath_owners",
      memory_bytes: 402_653_184,
      home_id: nil
    }

    def adopt(_server, ledger, _heir), do: {:ok, [%{@old | ledger: ledger}]}
    def fence(_server, %{session: {:before, _id}}), do: :pending
    def fence(server, tag), do: Locus.DirectLauncher.fence(server, tag)
    defdelegate spawn(server, spec), to: Locus.DirectLauncher
    defdelegate release(server, handle, grace_ms), to: Locus.DirectLauncher
    defdelegate send(handle, data), to: Locus.DirectLauncher
    defdelegate signal(handle, signal), to: Locus.DirectLauncher
    defdelegate resize(handle, rows, cols), to: Locus.DirectLauncher
    defdelegate place(server, id, whose, owner), to: Locus.DirectLauncher
    defdelegate drop(server, id), to: Locus.DirectLauncher
  end

  defmodule Placing do
    @moduledoc false
    # The direct launcher, telling the test each place made and dropped and
    # the place each spawn names; a place is refused while the test's
    # server says so, and held, as a keeper with no room holds one, until
    # the test answers it while its server says `hold_place`.
    import Kernel, except: [send: 2]

    def place(server, id, whose, owner) do
      Kernel.send(server[:test], {:placed, id, whose, owner})

      cond do
        server[:refuse_place] ->
          {:error, {:refused, "bad_request"}}

        server[:hold_place] ->
          # Its drop answers it at once, as the keeper's client answers a
          # place still waiting for room that it drops.
          :yes = :global.register_name({__MODULE__, id}, self())
          Kernel.send(server[:test], {:place_held, self()})
          Kernel.send(server[:test], {:place_held, id, whose, self()})

          receive do
            {:place_answer, answer} -> answer
          end

        true ->
          Locus.DirectLauncher.place(server, id, whose, owner)
      end
    end

    def drop(server, id) do
      Kernel.send(server[:test], {:dropped, id})

      case :global.whereis_name({__MODULE__, id}) do
        pid when is_pid(pid) -> Kernel.send(pid, {:place_answer, {:error, :dropped}})
        :undefined -> :ok
      end

      :ok
    end

    def spawn(server, spec) do
      Kernel.send(server[:test], {:spawned_in, spec.place})
      Locus.DirectLauncher.spawn(server, spec)
    end

    defdelegate adopt(server, ledger, heir), to: Locus.DirectLauncher
    defdelegate fence(server, tag), to: Locus.DirectLauncher
    defdelegate release(server, handle, grace_ms), to: Locus.DirectLauncher
    defdelegate send(handle, data), to: Locus.DirectLauncher
    defdelegate signal(handle, signal), to: Locus.DirectLauncher
    defdelegate resize(handle, rows, cols), to: Locus.DirectLauncher
  end

  defmodule KeeperEncoding do
    @moduledoc false
    # A launcher that starts nothing: it encodes the spawn a session asks
    # for as the keeper's channel would (`Prima.KeeperProtocol.encode/1`)
    # and tells the test whether the keeper would take it.
    def adopt(_test, _ledger, _owner), do: {:ok, []}
    def pool_stats(_test, "backends"), do: {:ok, %{size: 4, free: 4, quarantined: 0}}
    def place(_test, _id, _whose, _owner), do: {:ok, nil}
    def drop(_test, _id), do: :ok

    def spawn(test, spec) do
      request =
        spec
        |> Map.take([:place, :argv, :env, :pool, :memory_bytes, :cpu_quota, :pty, :hosts])
        |> Map.merge(%{
          type: :spawn,
          id: "encoded",
          attach: %{path: "/tmp/not-opened.sock", token: String.duplicate("a", 64)}
        })

      encoded =
        try do
          _ = Prima.KeeperProtocol.encode(request)
          :ok
        rescue
          error in ArgumentError -> {:error, Exception.message(error)}
        end

      send(test, {:spawn_encoded, map_size(spec.env), spec.env["TERM"], encoded})
      {:error, {:refused, "capacity"}}
    end
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

    start_supervised!({Owners,
     Keyword.merge(
       [
         boot: "bb_owners",
         launcher: Stub,
         launcher_server: stub,
         supervisor: supervisor,
         clock: fn -> Agent.get(clock, & &1) end,
         stop_grace_ms: 200,
         # A place here is answered at once, so a preparation held at its
         # pool read ends at its bound soon after.
         place_wait_ms: 500,
         pool_timeout_ms: 500,
         bounds: [restart_backoff_ms: [300, 600], crash_window_ms: 60_000, max_crashes: 3],
         session_opts: [
           launcher: Locus.DirectLauncher,
           launcher_server: [kept_root: root],
           release_timeout_ms: 5_000
         ]
       ],
       opts
     )})
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
        env: %{},
        home: :scratch,
        home_max_bytes: nil,
        hosts: nil
      },
      Map.new(opts)
    )
  end

  # A sync of `server` at `(g, e)` defining `programs`, their environment
  # opened as given.
  defp sync(owners, server, {g, e}, programs, opts \\ []) do
    message = %{
      type: :sync,
      owner: %{athanor: Keyword.get(opts, :athanor, @athanor), server: server},
      athanor_memory_bytes: Keyword.get(opts, :athanor_memory_bytes),
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

  defp invoke(server, {g, e}, athanor \\ @athanor),
    do: %{athanor: athanor, server: server, generation: g, epoch: e}

  # A lifetime of its own for each open, unless the test asks again for one.
  defp lifetime,
    do: Prima.LocusBackends.new_lifetime("bb_owners", :crypto.strong_rand_bytes(16))

  defp open(owners, server, version, program, opts \\ []) do
    athanor = Keyword.get(opts, :athanor, @athanor)

    message = %{
      type: :open,
      owner: %{athanor: athanor, server: server},
      e: elem(version, 1),
      program: program,
      home_id: Keyword.get(opts, :home_id),
      key: Keyword.get(opts, :key, "k"),
      mode: Keyword.get(opts, :mode, :run),
      lifetime: Keyword.get_lazy(opts, :lifetime, &lifetime/0),
      argv: Keyword.get(opts, :argv, []),
      rows: Keyword.get(opts, :rows),
      cols: Keyword.get(opts, :cols)
    }

    Owners.open(owners, invoke(server, version, athanor), message)
  end

  defp session_pid(owners, server, version, id) do
    {:ok, pid, _mode, _ended_by} = Owners.session(owners, invoke(server, version), id)
    pid
  end

  defp lines(pid, after_seq \\ 0, n) do
    wait_until(
      fn -> length(Backend.recv(pid, after_seq, 1_000).lines) >= n end,
      10_000
    )

    Enum.map(Backend.recv(pid, after_seq, 0).lines, & &1.text)
  end

  # A terminal's chunks past `after`, read until `done?` holds of all of
  # them together: those bytes and the last chunk's number.
  defp output(pid, after_seq, done?, seen \\ "") do
    if done?.(seen) do
      {seen, after_seq}
    else
      %{chunks: chunks} = Backend.recv(pid, after_seq, 5_000)
      assert chunks != [], "no output came after #{inspect(seen)}"
      output(pid, List.last(chunks).seq, done?, seen <> Enum.map_join(chunks, & &1.bytes))
    end
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
      assert {:error, :unknown_owner} = Owners.admit(owners, invoke("srv", {1, 1}))
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

  describe "a program's hosts" do
    test "go with each process it starts, and a process refused for them refuses the open so",
         ctx do
      for code <- ~w(hosts_unresolved guard_unavailable) do
        owners =
          start_owners(ctx,
            session_opts: [launcher: HostsLauncher, launcher_server: {self(), code}]
          )

        listed = [program("listed", @idle, hosts: ["api.example.com"]), program("open", @idle)]
        assert {:ok, _} = sync(owners, "srv", {1, 1}, listed)

        assert {:error, refusal} = open(owners, "srv", {1, 1}, "listed", key: "k")
        assert refusal == String.to_existing_atom(code)
        assert_receive {:spec, %{hosts: ["api.example.com"]}}

        assert {:error, _} = open(owners, "srv", {1, 1}, "open", key: "k")
        assert_receive {:spec, spec}
        refute Map.has_key?(spec, :hosts)

        stop_supervised!(Owners)
      end
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

      # A hello reports the pool's uids and no memory: the keeper's pool
      # alone admits a session's.
      assert {:ok, %{boot: "bb_owners", pool: %{size: 2, free: 2}} = hello} =
               control(owners, 1, %{type: :hello, g: 1, cyfr_boot: "boot_test"})

      refute Map.has_key?(hello, :memory)
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
    for ending <- [:close, :retire, :lapse] do
      @tag ending: ending
      test "a #{ending} wakes an in-flight receive and no later line revives its session", ctx do
        owners = start_owners(ctx)
        kept = [program("cat", "exec cat", home: :kept)]
        assert {:ok, _} = sync(owners, "a", {1, 1}, kept)
        assert {:ok, %{session: id}} = open(owners, "a", {1, 1}, "cat", home_id: @home)
        pid = session_pid(owners, "a", {1, 1}, id)
        assert :running = Backend.send_lines(pid, ["before"])
        assert lines(pid, 1) == ["before"]

        receiving = Task.async(fn -> Backend.recv(pid, 1, 5_000) end)
        wait_until(fn -> :sys.get_state(pid).waiters != [] end, 2_000)

        case ctx.ending do
          :close ->
            assert :ok = Backend.close(pid)

          :retire ->
            assert {:ok, %{state: :absent}} =
                     control(owners, 1, %{
                       type: :home,
                       op: :retire,
                       athanor: @athanor,
                       home_id: @home
                     })

          :lapse ->
            advance(ctx, 30_000)
            assert :ok = LeaseSweeper.sweep(owners)
        end

        assert %{running: false, lines: []} = Task.await(receiving)

        if ctx.ending == :lapse do
          wait_until(
            fn -> Owners.admit(owners, invoke("a", {1, 1})) == {:error, :unknown_owner} end,
            5_000
          )

          refute Process.alive?(pid)
        else
          assert {:ended, nil} = Backend.send_lines(pid, ["after"])
          assert %{running: false, lines: []} = Backend.recv(pid, 1, 0)
        end
      end
    end

    test "an open answers its own lifetime's process while it runs, and another lifetime starts it again once it ended",
         ctx do
      owners = start_owners(ctx)
      assert {:ok, _} = sync(owners, "a", {1, 1}, [program("cat", "exec cat")])
      one = [lifetime: lifetime()]

      assert {:ok, %{status: :running, session: first, resumed: false} = opened} =
               open(owners, "a", {1, 1}, "cat", one)

      assert opened == %{status: :running, session: first, resumed: false}

      assert {:ok, %{session: ^first, resumed: true}} = open(owners, "a", {1, 1}, "cat", one)
      assert {:ok, %{session: other, resumed: false}} = open(owners, "a", {1, 1}, "cat", key: "b")
      assert other != first

      pid = session_pid(owners, "a", {1, 1}, first)
      :ok = Backend.close(pid)
      assert %{running: false} = Backend.recv(pid, 0, 0)

      assert {:error, :lifetime_over} = open(owners, "a", {1, 1}, "cat", one)
      assert {:ok, %{session: again, resumed: false}} = open(owners, "a", {1, 1}, "cat")
      assert again != first

      # The ended session is still answered, as ended.
      assert {:ok, ^pid, :run, nil} = Owners.session(owners, invoke("a", {1, 1}), first)

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
      programs = [program("scratch", @idle), program("kept", @idle, home: :kept)]
      assert {:ok, _} = sync(owners, "a", {1, 1}, programs)
      v = {1, 1}

      for {name, opts} <- [
            {"kept", []},
            {"kept", [mode: :terminal, rows: 24, cols: 80]},
            {"scratch", [home_id: @home]},
            {"scratch", [home_id: @home, mode: :terminal, rows: 24, cols: 80]}
          ] do
        assert {:error, :bad_request} = open(owners, "a", v, name, opts), inspect({name, opts})
      end

      # A terminal is a session of its own beside a run of the same key,
      # in a kept home or a scratch one.
      for {name, opts} <- [{"kept", [home_id: @home]}, {"scratch", []}] do
        assert {:ok, %{session: run}} = open(owners, "a", v, name, opts)
        terminal = [lifetime: lifetime(), mode: :terminal, rows: 24, cols: 80] ++ opts
        assert {:ok, %{session: id} = opened} = open(owners, "a", v, name, terminal)
        assert opened == %{status: :running, session: id, resumed: false}
        assert id != run
        assert {:ok, pid, :terminal, nil} = Owners.session(owners, invoke("a", v), id)
        assert {:ok, %{session: ^id, resumed: true}} = open(owners, "a", v, name, terminal)

        # Gone before the test ends, so nothing of them outlives it.
        for session <- [pid, session_pid(owners, "a", v, run)],
            do: :ok = Backend.stop(session, 0)
      end
    end

    test "a terminal opens at the open's size, and a resize reaches it", ctx do
      owners = start_owners(ctx)

      assert {:ok, _} =
               sync(owners, "a", {1, 1}, [program("size", "stty size; read x; stty size")])

      assert {:ok, %{session: id}} =
               open(owners, "a", {1, 1}, "size", mode: :terminal, rows: 24, cols: 80)

      pid = session_pid(owners, "a", {1, 1}, id)
      {first, seq} = output(pid, 0, &String.contains?(&1, "\n"))
      assert first == "24 80\r\n"

      assert :running = Backend.resize(pid, 50, 132)
      assert :running = Backend.input(pid, "\r")
      {rest, _seq} = output(pid, seq, &String.contains?(&1, "50 132\r\n"))
      assert rest == "\r\n50 132\r\n"
      :ok = Backend.stop(pid, 0)
    end

    # A terminal session's process was told no terminal type, so `clear`
    # and a full-screen program could not draw on it.
    test "a terminal is told the terminal type, a run is told none, and a program's own " <>
           "TERM is kept",
         ctx do
      owners = start_owners(ctx)
      # What the program's environment holds: bash, which runs the command,
      # sets a TERM of its own when none is given but does not export it.
      say = ~s{printf '[%s]\\n' "$(printenv TERM || echo none)"; read x}

      assert {:ok, _} =
               sync(owners, "a", {1, 1}, [
                 program("plain", say),
                 program("own", say, env: %{"TERM" => "vt100"})
               ])

      terminal = [mode: :terminal, rows: 24, cols: 80]

      for {name, opts, seen} <- [
            {"plain", terminal, "[xterm-256color]\r\n"},
            {"own", terminal, "[vt100]\r\n"}
          ] do
        assert {:ok, %{session: id}} = open(owners, "a", {1, 1}, name, opts)
        pid = session_pid(owners, "a", {1, 1}, id)
        assert {^seen, _seq} = output(pid, 0, &String.contains?(&1, "\n"))
        :ok = Backend.stop(pid, 0)
      end

      assert {:ok, %{session: run}} = open(owners, "a", {1, 1}, "plain")
      pid = session_pid(owners, "a", {1, 1}, run)
      assert lines(pid, 1) == ["[none]"]
      :ok = Backend.stop(pid, 0)
    end

    # A row at the keeper's bound was given TERM past it: its terminal's
    # spawn could not be encoded for the keeper, and never started.
    test "a terminal on a row at its environment's bound asks for a spawn the keeper takes",
         ctx do
      owners =
        start_owners(ctx,
          session_opts: [
            launcher: KeeperEncoding,
            launcher_server: self(),
            release_timeout_ms: 5_000
          ]
        )

      env = Map.new(1..LocusBackends.max_env_names(), &{"V#{&1}", "value"})
      assert {:ok, _} = sync(owners, "a", {1, 1}, [program("full", "cat", env: env)])
      _ = open(owners, "a", {1, 1}, "full", mode: :terminal, rows: 24, cols: 80)
      max_env = Prima.KeeperProtocol.request_bounds().max_env
      assert_receive {:spawn_encoded, ^max_env, "xterm-256color", :ok}, 5_000
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

    test "a full owner cannot forget a kept session whose process is still ending", ctx do
      owners = start_owners(ctx, stop_grace_ms: 3_000)

      assert {:ok, _} =
               sync(owners, "a", {1, 1}, [program("cat", "trap '' TERM; exec cat", home: :kept)])

      ids =
        for i <- 1..LocusBackends.max_sessions() do
          assert {:ok, %{session: id}} =
                   open(owners, "a", {1, 1}, "cat", home_id: @home, key: "k#{i}")

          id
        end

      [first | _] = ids
      backend = session_pid(owners, "a", {1, 1}, first)
      os_pid = :sys.get_state(backend).handle.pid
      :ok = Backend.close(backend)
      assert %{running: false} = Backend.recv(backend, 0, 0)
      assert File.exists?("/proc/#{os_pid}"), "the session's OS process still runs"
      assert {:error, :capacity} = open(owners, "a", {1, 1}, "cat", home_id: @home, key: "next")
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
          Enum.all?(hd(Map.values(held(owners))).sessions, fn {_id, s} -> not s.running end) and
            :sys.get_state(owners).reservations == %{}
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

  describe "reservations" do
    @mib 1_048_576

    # How many sessions hold a reservation: their places, and a scratch
    # session's uid.
    defp reserved(owners), do: map_size(:sys.get_state(owners).reservations)

    test "opens being prepared each hold their reservation, and one that ends refused gives it back",
         ctx do
      owners = start_owners(ctx)
      assert {:ok, _} = sync(owners, "a", {1, 1}, idle_programs(1))
      set_pool(ctx, :hang)

      pending =
        for key <- ["one", "two"],
            do: Task.async(fn -> open(owners, "a", {1, 1}, "b1", key: key) end)

      wait_until(fn -> map_size(:sys.get_state(owners).pending) == 2 end, 5_000)
      assert reserved(owners) == 2

      # A preparation that ends refused releases what it held.
      assert [{:error, :unavailable}, {:error, :unavailable}] = Task.await_many(pending)
      assert reserved(owners) == 0
      set_pool(ctx, pool(4))
      assert {:ok, %{resumed: false}} = open(owners, "a", {1, 1}, "b1", key: "three")
      assert reserved(owners) == 1
    end

    test "no count of the table's own refuses a session for memory: past the budget it had, an open is the pool's",
         ctx do
      owners = start_owners(ctx)
      ceiling = [athanor: "ath_x", athanor_memory_bytes: 384 * @mib]
      assert {:ok, _} = sync(owners, "a", {1, 1}, idle_programs(1), ceiling)
      set_pool(ctx, pool(8))

      # Six sessions of 384 MiB each, past an athanor ceiling of one: the
      # table counts none of them, the pool every one.
      for key <- ~w(one two three four five six),
          do: assert({:ok, _} = open(owners, "a", {1, 1}, "b1", athanor: "ath_x", key: key))

      assert reserved(owners) == 6

      # A sync at the held version carries a new ceiling, for the places of
      # its next sessions.
      assert {:ok, _} =
               sync(owners, "a", {1, 1}, idle_programs(1),
                 athanor: "ath_x",
                 athanor_memory_bytes: 768 * @mib
               )

      assert held(owners)
             |> Map.values()
             |> Enum.find(&(&1.server == "a"))
             |> Map.fetch!(:athanor_memory_bytes) ==
               768 * @mib
    end

    test "a resumed session is held once", ctx do
      owners = start_owners(ctx)
      assert {:ok, _} = sync(owners, "a", {1, 1}, idle_programs(1))
      one = [lifetime: lifetime()]
      assert {:ok, %{session: id, resumed: false}} = open(owners, "a", {1, 1}, "b1", one)
      assert {:ok, %{session: ^id, resumed: true}} = open(owners, "a", {1, 1}, "b1", one)
      assert reserved(owners) == 1
    end

    test "two opens of one lifetime prepared at once start one session and hold its bound once",
         ctx do
      owners = start_owners(ctx)
      assert {:ok, _} = sync(owners, "a", {1, 1}, idle_programs(1))
      set_pool(ctx, :hang)
      one = [lifetime: lifetime()]
      first = Task.async(fn -> open(owners, "a", {1, 1}, "b1", one) end)
      second = Task.async(fn -> open(owners, "a", {1, 1}, "b1", one) end)

      wait_until(
        fn ->
          Enum.any?(:sys.get_state(owners).pending, fn
            {_ref, %{continuation: {:open, froms, _ask}}} -> length(froms) == 2
            _other -> false
          end)
        end,
        5_000
      )

      assert reserved(owners) == 1
      Task.await_many([first, second])
      set_pool(ctx, pool(4))

      # Both refused by the hung pool; with an answering pool, one starts
      # the session and the other attaches to it.
      first = Task.async(fn -> open(owners, "a", {1, 1}, "b1", one) end)
      second = Task.async(fn -> open(owners, "a", {1, 1}, "b1", one) end)
      assert [{:ok, %{session: id}}, {:ok, %{session: id}}] = Task.await_many([first, second])
      assert reserved(owners) == 1
    end

    test "a caller that gives up leaves its open held until its preparation answers", ctx do
      owners = start_owners(ctx)
      assert {:ok, _} = sync(owners, "a", {1, 1}, idle_programs(1))
      set_pool(ctx, :hang)

      caller = Task.async(fn -> open(owners, "a", {1, 1}, "b1") end)
      wait_until(fn -> map_size(:sys.get_state(owners).pending) == 1 end, 5_000)
      Task.shutdown(caller, :brutal_kill)
      assert reserved(owners) == 1

      wait_until(fn -> reserved(owners) == 0 end, 5_000)
      set_pool(ctx, pool(4))
      assert {:ok, _} = open(owners, "a", {1, 1}, "b1", key: "two")
    end

    test "an owner retired while its open is prepared drops the reservation; its sessions hold theirs until gone",
         ctx do
      owners = start_owners(ctx)
      assert {:ok, _} = sync(owners, "a", {1, 1}, idle_programs(1))
      assert {:ok, _} = open(owners, "a", {1, 1}, "b1", key: "running")

      set_pool(ctx, :hang)
      pending = Task.async(fn -> open(owners, "a", {1, 1}, "b1", key: "prepared") end)
      wait_until(fn -> map_size(:sys.get_state(owners).pending) == 1 end, 5_000)
      assert reserved(owners) == 2

      release = %{type: :release, owners: [%{athanor: @athanor, server: "a", e: 1}]}
      assert {:ok, %{released: [_]}} = control(owners, 1, release)
      assert {:error, :lapsed} = Task.await(pending)

      # The released owner's session stops within its grace; until its
      # process is gone it holds its bound, and then nothing is held.
      wait_until(fn -> held(owners) == %{} end, 10_000)
      assert reserved(owners) == 0
    end

    test "a dead session process keeps its bound held until its launcher says its OS process is gone",
         ctx do
      owners = start_owners(ctx)
      assert {:ok, _} = sync(owners, "a", {1, 1}, idle_programs(1))
      assert {:ok, %{session: id}} = open(owners, "a", {1, 1}, "b1")
      backend = session_pid(owners, "a", {1, 1}, id)
      handle = :sys.get_state(backend).handle
      launcher = handle.server
      os_pid = handle.pid

      on_exit(fn ->
        try do
          :sys.resume(launcher)
        catch
          :exit, _ -> :ok
        end
      end)

      # The launcher, held still, has not yet ended the process its dead
      # owner leaves to it.
      :sys.suspend(launcher)
      Process.exit(backend, :kill)
      wait_until(fn -> not Process.alive?(backend) end, 5_000)
      wait_until(fn -> hd(Map.values(held(owners))).sessions[id].pid == nil end, 5_000)
      assert File.exists?("/proc/#{os_pid}"), "the session's OS process still runs"

      assert reserved(owners) == 1

      # Once it has, as the spawn's heir hears, the bound is free again.
      :sys.resume(launcher)
      wait_until(fn -> reserved(owners) == 0 end, 10_000)
      assert {:ok, _} = open(owners, "a", {1, 1}, "b1", key: "next")
    end

    test "a session that dies before it asks for its process is cleared by its fence", ctx do
      owners =
        start_owners(ctx,
          bounds: [restart_backoff_ms: [10_000], crash_window_ms: 60_000, max_crashes: 3]
        )

      assert {:ok, _} = sync(owners, "a", {1, 1}, [program("crash", "exit 3")])
      assert {:ok, _} = open(owners, "a", {1, 1}, "crash")
      wait_until(fn -> hd(Map.values(held(owners))).programs["crash"].restarts == 1 end, 10_000)
      wait_until(fn -> reserved(owners) == 0 end, 10_000)

      # The next open waits out the crash's backoff before its process is
      # asked for; its session dies in the wait.
      opening = Task.async(fn -> open(owners, "a", {1, 1}, "crash") end)

      delayed = fn ->
        Enum.find_value(hd(Map.values(held(owners))).sessions, fn {_id, session} ->
          session.running and not session.started and session.pid
        end)
      end

      wait_until(fn -> delayed.() != nil end, 5_000)
      waiting = delayed.()

      assert reserved(owners) == 1
      Process.exit(waiting, :kill)
      assert {:error, :internal} = Task.await(opening)

      # The launcher's fence answers that it holds no process of it, and
      # will start none.
      wait_until(fn -> reserved(owners) == 0 end, 5_000)
      assert Reservations.endings(:sys.get_state(owners).reservations) == %{}
    end

    test "a second ask of a lifetime waits for the launch, and hears its refusal", ctx do
      launcher = {self(), ctx.clock, Agent.get(ctx.clock, & &1)}

      owners =
        start_owners(ctx, session_opts: [launcher: BeforeSpawn, launcher_server: launcher])

      assert {:ok, _} = sync(owners, "a", {1, 1}, idle_programs(1))
      one = [lifetime: lifetime()]
      first = Task.async(fn -> open(owners, "a", {1, 1}, "b1", one) end)
      assert_receive {:before_spawn, backend}, 2_000
      second = Task.async(fn -> open(owners, "a", {1, 1}, "b1", one) end)

      assert Task.yield(second, 250) == nil, "a second ask was told running before the launch"

      send(backend, :go)
      assert {:error, refusal} = Task.await(first, 5_000)
      assert {:error, ^refusal} = Task.await(second, 5_000)
    end

    test "a second ask of a lifetime being prepared shares the first's preparation and its refusal",
         ctx do
      owners = start_owners(ctx)
      assert {:ok, _} = sync(owners, "a", {1, 1}, idle_programs(1))
      set_pool(ctx, {:held, self(), pool(0)})
      one = [lifetime: lifetime()]
      first = Task.async(fn -> open(owners, "a", {1, 1}, "b1", one) end)
      assert_receive {:pool_read, reading}, 2_000
      second = Task.async(fn -> open(owners, "a", {1, 1}, "b1", one) end)

      # The box has room for one bound: the second asks for none of its own.
      assert Task.yield(second, 250) == nil
      refute_received {:pool_read, _another}

      send(reading, :answer)
      assert {:error, :capacity} = Task.await(first, 5_000)
      assert {:error, :capacity} = Task.await(second, 5_000)
    end

    test "a session that dies before its launcher has its request is cleared by the launcher's fence",
         ctx do
      owners =
        start_owners(ctx,
          session_opts: [
            launcher: BeforeSpawn,
            launcher_server: {self(), ctx.clock, Agent.get(ctx.clock, & &1)}
          ]
        )

      assert {:ok, _} = sync(owners, "a", {1, 1}, idle_programs(1))
      opening = Task.async(fn -> open(owners, "a", {1, 1}, "b1") end)
      assert_receive {:before_spawn, backend}, 2_000
      Process.exit(backend, :kill)
      assert {:error, :internal} = Task.await(opening)

      wait_until(
        fn -> map_size(Reservations.endings(:sys.get_state(owners).reservations)) == 1 end,
        5_000
      )

      assert reserved(owners) == 1
      advance(ctx, 86_400_000)

      # A fence that read the clock before it moved answers unavailable,
      # maybe after every sweep so far has found it asking, and only a
      # later sweep asks again. These owners have no periodic sweeper
      # (`LeaseSweeper`), so each poll drives one.
      wait_until(
        fn ->
          :ok = Owners.sweep(owners)
          held(owners) == %{} and reserved(owners) == 0
        end,
        5_000,
        "the owner gone and its bound freed"
      )

      assert reserved(owners) == 0
    end

    test "a release timeout ends the wait, never the hold, while the process runs", ctx do
      owners =
        start_owners(ctx,
          stop_grace_ms: 0,
          session_opts: [
            launcher: Locus.DirectLauncher,
            launcher_server: [kept_root: ctx.root],
            release_timeout_ms: 25
          ]
        )

      assert {:ok, _} = sync(owners, "a", {1, 1}, idle_programs(1))
      assert {:ok, %{session: id}} = open(owners, "a", {1, 1}, "b1")
      backend = session_pid(owners, "a", {1, 1}, id)
      handle = :sys.get_state(backend).handle

      on_exit(fn ->
        try do
          :sys.resume(handle.server)
        catch
          :exit, _ -> :ok
        end
      end)

      :sys.suspend(handle.server)
      :erlang.trace(backend, true, [:receive])
      :ok = Backend.close(backend)
      assert_receive {:trace, ^backend, :receive, :release_timeout}, 2_000
      :erlang.trace(backend, false, [:receive])
      Backend.recv(backend, 0, 0)
      assert File.exists?("/proc/#{handle.pid}")
      assert reserved(owners) == 1

      # The launcher's word frees it.
      :sys.resume(handle.server)
      wait_until(fn -> reserved(owners) == 0 end, 10_000)
    end

    test "a lifetime closed in the table's last boot is refused by the next, though no fence outlived it",
         ctx do
      owners = start_owners(ctx)
      assert {:ok, _} = sync(owners, "a", {1, 1}, idle_programs(1))
      lifetime = lifetime()
      assert {:ok, _} = open(owners, "a", {1, 1}, "b1", lifetime: lifetime)
      named = %{program: "b1", home_id: nil, key: "k", mode: :run, lifetime: lifetime}
      assert :ok = Owners.close(owners, invoke("a", {1, 1}), named)

      stop_supervised!(Owners)
      owners = start_owners(ctx, boot: "bb_next")
      assert {:ok, _} = sync(owners, "a", {1, 1}, idle_programs(1))

      assert open(owners, "a", {1, 1}, "b1", lifetime: lifetime) == {:error, :lifetime_over},
             "the last boot's closed lifetime started again"

      assert sessions_of(owners, "a") == []
    end

    test "a table restarted by its supervisor adopts the processes its predecessor followed",
         ctx do
      owner_name = :owners_restart_owners
      sessions_name = :owners_restart_sessions

      children = [
        {Owners,
         [
           name: owner_name,
           boot: "bb_owners",
           launcher: Stub,
           launcher_server: ctx.stub,
           supervisor: sessions_name,
           clock: fn -> Agent.get(ctx.clock, & &1) end,
           session_opts: [launcher: Locus.DirectLauncher, launcher_server: [kept_root: ctx.root]]
         ]},
        {DynamicSupervisor, name: sessions_name, strategy: :one_for_one}
      ]

      # The test's supervisor owns the root and stops it before any on_exit
      # callback runs. Linked to the test process, the root ended with it,
      # and a stop from a callback that met it ending exited.
      start_supervised!(%{
        id: :owners_restart_root,
        start: {Supervisor, :start_link, [children, [strategy: :rest_for_one]]},
        type: :supervisor
      })

      old_owner = Process.whereis(owner_name)
      assert {:ok, _} = sync(old_owner, "a", {1, 1}, idle_programs(1))
      assert {:ok, %{session: id}} = open(old_owner, "a", {1, 1}, "b1")
      backend = session_pid(old_owner, "a", {1, 1}, id)
      handle = :sys.get_state(backend).handle

      on_exit(fn ->
        try do
          :sys.resume(handle.server)
        catch
          :exit, _ -> :ok
        end
      end)

      :sys.suspend(handle.server)
      Process.exit(old_owner, :kill)

      wait_until(
        fn ->
          Process.whereis(owner_name) not in [nil, old_owner] and
            Process.whereis(sessions_name) != nil
        end,
        5_000
      )

      new_owner = Process.whereis(owner_name)
      assert {:ok, _} = sync(new_owner, "a", {1, 1}, idle_programs(1))
      assert File.exists?("/proc/#{handle.pid}")
      assert reserved(new_owner) == 1

      # Its end, told to the adopting table, frees its bound.
      :sys.resume(handle.server)
      wait_until(fn -> reserved(new_owner) == 0 end, 10_000)
    end

    test "a release heard before the adoption that names it stays released", ctx do
      counter = start_supervised!({Agent, fn -> 0 end}, id: :adoption_calls)

      owners =
        start_owners(ctx,
          session_opts: [launcher: AdoptionRace, launcher_server: {self(), counter}]
        )

      assert :sys.get_state(owners).adopted == false

      # Nothing is known to be released before the launcher has answered.
      assert {:error, :unavailable} =
               Owners.close(owners, invoke("a", {1, 1}), %{
                 program: "b1",
                 home_id: nil,
                 key: "k",
                 mode: :run,
                 lifetime: lifetime()
               })

      :ok = Owners.sweep(owners)
      assert_receive {:adoption_snapshot, worker, ^owners, tag}, 2_000

      # An adoption pending is shown as its kind, in a status that reads.
      status = inspect(:sys.get_status(owners), limit: :infinity, printable_limit: :infinity)
      assert status =~ "adopting: true"
      send(owners, {AdoptionRace, {:heir, tag}, :released})
      assert reserved(owners) == 0
      send(worker, :go)
      wait_until(fn -> :sys.get_state(owners).adopted end, 5_000)
      for _ <- 1..3, do: Owners.sweep(owners)
      wait_until(fn -> reserved(owners) == 0 end, 5_000)
      assert reserved(owners) == 0
    end

    @tag timeout: 30_000
    test "a spawn whose call timed out stays held until the keeper confirms its retirement",
         ctx do
      %{name: client, fake: fake} = Locus.Test.FakeKeeper.start_client!()

      owners =
        start_owners(ctx,
          session_opts: [launcher: Locus.Keeper, launcher_server: client]
        )

      assert {:ok, _} = sync(owners, "a", {1, 1}, idle_programs(1))

      on_exit(fn ->
        try do
          :sys.resume(fake)
        catch
          :exit, _ -> :ok
        end
      end)

      # The keeper is held once the session's place is made, as its pool is
      # read, so the spawn is the call that waits.
      set_pool(ctx, {:held, self(), pool(4)})
      opening = Task.async(fn -> open(owners, "a", {1, 1}, "b1") end)
      assert_receive {:pool_read, reader}, 5_000
      :sys.suspend(fake)
      send(reader, :answer)
      wait_until(fn -> map_size(:sys.get_state(client).requests) == 1 end, 5_000)
      _result = Task.await(opening, 20_000)
      ledger = :sys.get_state(owners).ledger
      {:ok, unconfirmed} = Locus.Keeper.adopt(client, ledger, owners)
      assert length(unconfirmed) == 1
      held = reserved(owners)
      :sys.resume(fake)
      wait_until(fn -> :sys.get_state(client).requests == %{} end, 10_000)
      assert held == 1

      # The keeper's word, to the spawn's heir, frees it.
      wait_until(fn -> reserved(owners) == 0 end, 10_000)
    end

    @tag timeout: 30_000
    test "a session whose spawn is refused after the keeper made it keeps its reservation until the keeper's release",
         ctx do
      %{name: client, fake: fake} = Locus.Test.FakeKeeper.start_client!()

      owners =
        start_owners(ctx,
          session_opts: [launcher: Locus.Keeper, launcher_server: client]
        )

      assert {:ok, _} = sync(owners, "a", {1, 1}, idle_programs(1))
      :ok = Locus.Test.FakeKeeper.mode(fake, {:exec_failed, self()})

      # The refusal answers the open; what the keeper made is still its own.
      assert {:error, :unavailable} = open(owners, "a", {1, 1}, "b1")
      assert_receive {:exec_failed, spawn_id}, 5_000
      assert reserved(owners) == 1

      :ok = Locus.Test.FakeKeeper.mode(fake, :normal)
      :ok = Locus.Test.FakeKeeper.released(fake, spawn_id)
      wait_until(fn -> reserved(owners) == 0 end, 10_000)
      assert {:ok, _} = open(owners, "a", {1, 1}, "b1", key: "two")
    end

    @tag timeout: 30_000
    test "a session keeps its reservation when the keeper's channel is lost: nobody but the keeper says its process is gone",
         ctx do
      %{name: client, fake: fake} = Locus.Test.FakeKeeper.start_client!()

      owners =
        start_owners(ctx,
          session_opts: [launcher: Locus.Keeper, launcher_server: client]
        )

      assert {:ok, _} = sync(owners, "a", {1, 1}, idle_programs(1))
      assert {:ok, _} = open(owners, "a", {1, 1}, "b1")
      assert reserved(owners) == 1
      [session] = Map.keys(:sys.get_state(owners).pids)
      client_down = Process.monitor(client)

      :ok = Locus.Test.FakeKeeper.close(fake)
      assert_receive {:DOWN, ^client_down, :process, ^client, {:shutdown, :channel_lost}}, 5_000

      # What the client told before it stopped has reached the session, and
      # what the session told has reached the table.
      _ = :sys.get_state(session)
      assert reserved(owners) == 1
    end

    test "a session's bound is released once its process is confirmed gone, not when it is asked to end",
         ctx do
      # A grace long enough that the checks below run inside it.
      owners = start_owners(ctx, stop_grace_ms: 3_000)
      assert {:ok, _} = sync(owners, "a", {1, 1}, [program("cat", ~s(trap '' TERM; exec cat))])
      assert {:ok, %{session: id}} = open(owners, "a", {1, 1}, "cat")
      pid = session_pid(owners, "a", {1, 1}, id)

      # Closed, the session answers ended at once while its process takes
      # its grace to go: its bound stays held until then.
      :ok = Backend.close(pid)
      assert %{running: false} = Backend.recv(pid, 0, 0)
      assert reserved(owners) == 1

      wait_until(fn -> reserved(owners) == 0 end, 10_000)
      assert {:ok, _} = open(owners, "a", {1, 1}, "cat", key: "two")
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

    test "a released owner serves no open: unknown at once, nothing started", ctx do
      owners = start_owners(ctx)
      assert {:ok, _} = sync(owners, "a", {1, 1}, idle_programs(1))
      assert {:ok, %{session: id}} = open(owners, "a", {1, 1}, "b1")
      pid = session_pid(owners, "a", {1, 1}, id)

      release = %{type: :release, owners: [%{athanor: @athanor, server: "a", e: 1}]}
      assert {:ok, %{released: [%{server: "a"}]}} = control(owners, 1, release)

      # A release unroutes the owner at once and stops its sessions after.
      assert {:error, :unknown_owner} = open(owners, "a", {1, 1}, "b2")
      assert Owners.admit(owners, invoke("a", {1, 1})) == {:error, :unknown_owner}
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

  # An open of each key held before it makes its home, with its worker.
  defp preparing(ctx, owners, keys) do
    test = self()

    for key <- keys do
      Agent.update(ctx.stub, &Map.put(&1, :before_ensure, test))
      opening = Task.async(fn -> open(owners, "a", {1, 1}, "kept", home_id: @home, key: key) end)
      assert_receive {:home_about_to_be_created, worker}, 2_000
      {opening, worker}
    end
  end

  # What `ask` is answered while what it would wait for is still held.
  defp at_once(ask) do
    case Task.yield(Task.async(ask), 2_000) do
      {:ok, answer} -> answer
      nil -> :waits
    end
  end

  defp running_in(owners, server) do
    for {_id, %{server: ^server, state: :running} = owner} <- held(owners),
        {id, %{running: true}} <- owner.sessions,
        do: id
  end

  describe "places" do
    defp placing(ctx, extra \\ []),
      do: [
        launcher: Placing,
        launcher_server: [kept_root: ctx.root, test: self()] ++ extra,
        release_timeout_ms: 5_000
      ]

    test "a session's place is made for the table first, of its kind, athanor and row, named by " <>
           "its spawn, and dropped once nothing of it is left",
         ctx do
      owners = start_owners(ctx, session_opts: placing(ctx))
      assert {:ok, _} = sync(owners, "a", {1, 1}, idle_programs(1))
      set_pool(ctx, {:held, self(), pool(4)})
      lifetime = lifetime()
      opening = Task.async(fn -> open(owners, "a", {1, 1}, "b1", lifetime: lifetime) end)

      first =
        receive do
          {:placed, _id, _whose, _owner} = placed -> placed
          {:pool_read, _reader} -> :pool_read_first
        after
          2_000 -> :none
        end

      assert_receive {:pool_read, reader}, 2_000
      send(reader, :answer)
      assert {:ok, %{session: id}} = Task.await(opening, 5_000)
      assert_received {:spawned_in, spawned_in}
      refute_received {:dropped, _id}

      named = %{program: "b1", home_id: nil, key: "k", mode: :run, lifetime: lifetime}
      assert :ok = Owners.close(owners, invoke("a", {1, 1}), named)
      assert_receive {:dropped, dropped}, 5_000

      assert %{first: first, spawned_in: spawned_in, dropped: dropped} == %{
               first: {:placed, id, %{kind: "program", athanor: @athanor, subject: "a"}, owners},
               spawned_in: id,
               dropped: id
             }
    end

    test "a preparation that fails, or dies at its bound, leaves no place and starts nothing",
         ctx do
      owners = start_owners(ctx, session_opts: placing(ctx))
      assert {:ok, _} = sync(owners, "a", {1, 1}, idle_programs(1))

      answers =
        for pool <- [pool(0), :hang] do
          set_pool(ctx, pool)
          answer = open(owners, "a", {1, 1}, "b1")
          assert_received {:placed, id, _whose, _owner}
          assert_receive {:dropped, ^id}, 5_000
          answer
        end

      refute_received {:spawned_in, _place}
      assert answers == [{:error, :capacity}, {:error, :unavailable}]
      assert :sys.get_state(owners).reservations == %{}
    end

    test "a close that cancels a preparation leaves no place", ctx do
      owners = start_owners(ctx, session_opts: placing(ctx))
      assert {:ok, _} = sync(owners, "a", {1, 1}, [program("kept", @idle, home: :kept)])
      test = self()
      Agent.update(ctx.stub, &Map.put(&1, :before_ensure, test))
      lifetime = lifetime()

      opening =
        Task.async(fn ->
          open(owners, "a", {1, 1}, "kept", home_id: @home, lifetime: lifetime)
        end)

      assert_receive {:placed, id, %{kind: "program"}, ^owners}, 2_000
      assert_receive {:home_about_to_be_created, worker}, 2_000

      named = %{program: "kept", home_id: @home, key: "k", mode: :run, lifetime: lifetime}
      closing = Task.async(fn -> Owners.close(owners, invoke("a", {1, 1}), named) end)

      # Its place, granted, is given back at the close while its home is
      # still being made, and the close waits for that work.
      assert_receive {:dropped, ^id}, 5_000
      assert Task.yield(closing, 250) == nil
      assert reserved(owners) == 1
      send(worker, :continue_ensure)

      assert %{opened: Task.await(opening, 5_000), closed: Task.await(closing, 10_000)} == %{
               opened: {:error, :lifetime_over},
               closed: :ok
             }

      assert reserved(owners) == 0
      refute_received {:spawned_in, _place}
    end

    test "a close of an open still waiting for room answers closed at once, its place out of the queue",
         ctx do
      owners =
        start_owners(ctx,
          place_wait_ms: Locus.Launcher.place_wait_ms(),
          session_opts: placing(ctx, hold_place: true)
        )

      assert {:ok, _} = sync(owners, "a", {1, 1}, idle_programs(1))
      lifetime = lifetime()
      opening = Task.async(fn -> open(owners, "a", {1, 1}, "b1", lifetime: lifetime) end)
      assert_receive {:place_held, id, _whose, _placer}, 2_000

      named = %{program: "b1", home_id: nil, key: "k", mode: :run, lifetime: lifetime}
      started = System.monotonic_time(:millisecond)
      assert :ok = Owners.close(owners, invoke("a", {1, 1}), named)
      took = System.monotonic_time(:millisecond) - started

      # Answered well inside a second, never after the room's wait.
      assert took < 1_000, "the close waited #{took} ms"
      assert_received {:dropped, ^id}
      assert Task.await(opening, 1_000) == {:error, :lifetime_over}
      assert reserved(owners) == 0
      refute_received {:spawned_in, _place}
    end

    test "a session's place the keeper answers past 5 s opens it, and one refused for room is " <>
           "capacity with what holds the pool, logged by its need and free alone",
         ctx do
      owners =
        start_owners(ctx,
          place_wait_ms: Locus.Launcher.place_wait_ms(),
          session_opts: placing(ctx, hold_place: true)
        )

      assert {:ok, _} = sync(owners, "a", {1, 1}, idle_programs(1))
      opening = Task.async(fn -> open(owners, "a", {1, 1}, "b1", key: "one") end)
      assert_receive {:place_held, placer}, 2_000
      assert Task.yield(opening, 6_000) == nil
      send(placer, {:place_answer, {:ok, 402_653_184}})
      assert {:ok, %{resumed: false}} = Task.await(opening, 5_000)

      refusing = Task.async(fn -> open(owners, "a", {1, 1}, "b1", key: "two") end)
      assert_receive {:place_held, placer}, 2_000
      assert Task.yield(refusing, 6_000) == nil

      held = %{
        need: 402_653_184,
        free: 1_048_576,
        mine: [%{kind: "build", subject: nil, bytes: 905_969_664}],
        others_bytes: 268_435_456
      }

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send(placer, {:place_answer, {:error, {:no_memory, held}}})
          assert Task.await(refusing, 5_000) == {:error, {:capacity, held}}
        end)

      assert log =~ "no_memory: 402653184 bytes needed, 1048576 free"
      refute log =~ "905969664"
      refute log =~ "268435456"
      assert reserved(owners) == 1
    end

    test "a session refused while builds fill the pool is served again once they are released",
         ctx do
      owners = start_owners(ctx, session_opts: placing(ctx, hold_place: true))
      assert {:ok, _} = sync(owners, "a", {1, 1}, idle_programs(1))
      builds = %{need: 402_653_184, free: 0, mine: [], others_bytes: 2_147_483_648}

      refused = Task.async(fn -> open(owners, "a", {1, 1}, "b1") end)
      assert_receive {:place_held, first, _whose, placer}, 2_000
      send(placer, {:place_answer, {:error, {:no_memory, builds}}})
      assert Task.await(refused, 5_000) == {:error, {:capacity, builds}}
      assert_receive {:dropped, ^first}, 5_000
      assert reserved(owners) == 0

      # The builds released, the pool places the next open of the same key.
      served = Task.async(fn -> open(owners, "a", {1, 1}, "b1") end)
      assert_receive {:place_held, second, _whose, placer}, 2_000
      send(placer, {:place_answer, {:ok, 402_653_184}})
      assert {:ok, %{session: ^second, resumed: false}} = Task.await(served, 5_000)
      assert reserved(owners) == 1
    end

    test "each open refused for room carries its own place's holders: one athanor's are never another's",
         ctx do
      owners = start_owners(ctx, session_opts: placing(ctx, hold_place: true))
      assert {:ok, _} = sync(owners, "x", {1, 1}, idle_programs(1), athanor: "ath_x")
      assert {:ok, _} = sync(owners, "y", {1, 1}, idle_programs(1), athanor: "ath_y")

      x = Task.async(fn -> open(owners, "x", {1, 1}, "b1", athanor: "ath_x") end)
      assert_receive {:place_held, _x_id, %{athanor: "ath_x", subject: "x"}, x_placer}, 2_000
      y = Task.async(fn -> open(owners, "y", {1, 1}, "b1", athanor: "ath_y") end)
      assert_receive {:place_held, _y_id, %{athanor: "ath_y", subject: "y"}, y_placer}, 2_000

      # What the keeper answers each place: its own athanor's places, by
      # subject where they are the backends', and the other's as one sum.
      x_held = %{
        need: 402_653_184,
        free: 0,
        mine: [%{kind: "program", subject: "x", bytes: 536_870_912}],
        others_bytes: 805_306_368
      }

      y_held = %{
        need: 402_653_184,
        free: 0,
        mine: [%{kind: "terminal", subject: "y", bytes: 805_306_368}],
        others_bytes: 536_870_912
      }

      send(y_placer, {:place_answer, {:error, {:no_memory, y_held}}})
      send(x_placer, {:place_answer, {:error, {:no_memory, x_held}}})

      assert %{x: Task.await(x, 5_000), y: Task.await(y, 5_000)} == %{
               x: {:error, {:capacity, x_held}},
               y: {:error, {:capacity, y_held}}
             }
    end

    test "its place names its athanor's ceiling, at most the keeper's", ctx do
      owners = start_owners(ctx, session_opts: placing(ctx))
      max = Prima.KeeperProtocol.request_bounds().max_athanor_bytes

      programs = [
        program("big", @idle),
        program("small", @idle)
      ]

      assert {:ok, %{programs: [%{status: :idle}, %{status: :idle}]}} =
               sync(owners, "a", {1, 1}, programs, athanor_memory_bytes: 2048 * @mib)

      assert {:ok, _} = sync(owners, "b", {1, 1}, programs, athanor_memory_bytes: max + 1)
      assert {:ok, _} = sync(owners, "c", {1, 1}, programs)
      assert {:ok, _} = open(owners, "a", {1, 1}, "big")
      assert_received {:placed, _id, %{athanor_max_bytes: a_ceiling}, ^owners}
      assert {:ok, _} = open(owners, "b", {1, 1}, "small")
      assert_received {:placed, _id, %{athanor_max_bytes: b_ceiling}, ^owners}
      assert {:ok, _} = open(owners, "c", {1, 1}, "small")
      assert_received {:placed, _id, c_whose, ^owners}

      assert %{a: a_ceiling, b: b_ceiling, c: Map.has_key?(c_whose, :athanor_max_bytes)} ==
               %{a: 2048 * @mib, b: max, c: false}
    end

    test "a session whose place is refused starts nothing and holds nothing", ctx do
      owners = start_owners(ctx, session_opts: placing(ctx, refuse_place: true))
      assert {:ok, _} = sync(owners, "a", {1, 1}, idle_programs(1))

      assert open(owners, "a", {1, 1}, "b1") == {:error, :unavailable}
      assert_received {:placed, id, _whose, _owner}
      assert_receive {:dropped, ^id}, 5_000
      refute_received {:spawned_in, _place}
      assert :sys.get_state(owners).reservations == %{}
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

      assert {:ok, %{resumed: false, session: reopened}} =
               open(owners, "a", {1, 1}, "kept", home_id: @home, key: "after")

      # Open acknowledges the launch before the shell writes into the home.
      pid = session_pid(owners, "a", {1, 1}, reopened)
      assert %{lines: [%{text: "filled"}]} = Backend.recv(pid, 0, 5_000)
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

    test "a close waits for its lifetime's preparation, so nothing makes a home again once it is retired",
         ctx do
      owners = start_owners(ctx)
      assert {:ok, _} = sync(owners, "a", {1, 1}, [program("kept", @idle, home: :kept)])
      test = self()
      Agent.update(ctx.stub, &Map.put(&1, :before_ensure, test))
      lifetime = lifetime()
      named = %{program: "kept", home_id: @home, key: "k", mode: :run, lifetime: lifetime}

      opening =
        Task.async(fn ->
          open(owners, "a", {1, 1}, "kept", home_id: @home, lifetime: lifetime)
        end)

      assert_receive {:home_about_to_be_created, worker}, 2_000
      closing = Task.async(fn -> Owners.close(owners, invoke("a", {1, 1}), named) end)

      assert Task.yield(closing, 300) == nil,
             "closed was answered while the preparation could still make the home"

      send(worker, :continue_ensure)
      assert {:error, :lifetime_over} = Task.await(opening, 5_000)
      assert :ok = Task.await(closing, 5_000)

      retire = %{type: :home, op: :retire, athanor: @athanor, home_id: @home}
      assert {:ok, %{state: :absent}} = control(owners, 1, retire)
      refute File.exists?(Path.join(ctx.root, @home))
      assert sessions_of(owners, "a") == []
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

    for {op, state, there?} <- [{:retire, :absent, false}, {:reset, :empty, true}] do
      @tag op: op, answered: state, there?: there?
      test "a home's #{op} is conflict at once while any open prepares in it, and succeeds when asked again",
           ctx do
        owners = start_owners(ctx)
        assert {:ok, _} = sync(owners, "a", {1, 1}, [program("kept", @idle, home: :kept)])
        [{first, making}, {second, lost}] = preparing(ctx, owners, ["one", "two"])
        message = %{type: :home, op: ctx.op, athanor: @athanor, home_id: @home}
        change = fn -> control(owners, 1, message) end
        other = %{message | home_id: "vlt_01a09fee-2c3d-7e4f-8a5b-000000000002"}

        beside_both = at_once(change)
        another_home = at_once(fn -> control(owners, 1, other) end)
        send(making, :continue_ensure)
        Task.await(first, 5_000)
        beside_one = at_once(change)
        Process.exit(lost, :kill)
        Task.await(second, 5_000)
        again = change.()

        # The session the settled preparation started ends with the change.
        wait_until(fn -> running_in(owners, "a") == [] end, 5_000)

        assert %{
                 beside_both: beside_both,
                 another_home: match?({:ok, _}, another_home),
                 beside_one: beside_one,
                 again: again,
                 folder: File.exists?(Path.join(ctx.root, @home))
               } == %{
                 beside_both: {:error, :conflict},
                 another_home: true,
                 beside_one: {:error, :conflict},
                 again: {:ok, %{home_id: @home, state: ctx.answered}},
                 folder: ctx.there?
               }
      end
    end

    test "another owner's renewal is served, and its session runs, while a home's retire meets a held preparation",
         ctx do
      owners = start_owners(ctx)
      assert {:ok, _} = sync(owners, "a", {1, 1}, [program("kept", @idle, home: :kept)])
      assert {:ok, _} = sync(owners, "b", {1, 1}, idle_programs(1))
      assert {:ok, %{session: id}} = open(owners, "b", {1, 1}, "b1")
      [{opening, making}] = preparing(ctx, owners, ["one"])

      retire = %{type: :home, op: :retire, athanor: @athanor, home_id: @home}
      retired = at_once(fn -> control(owners, 1, retire) end)

      # Inside its lease, then past the one it had.
      advance(ctx, 20_000)
      renew = %{type: :renew, lease_ms: 30_000, owners: [%{athanor: @athanor, server: "b", e: 1}]}
      renewed = at_once(fn -> control(owners, 1, renew) end)
      advance(ctx, 11_000)
      :ok = Owners.sweep(owners)
      runs = running_in(owners, "b")

      send(making, :continue_ensure)
      Task.await(opening, 5_000)

      assert %{retired: retired, renewed: renewed, runs: runs} == %{
               retired: {:error, :conflict},
               renewed:
                 {:ok,
                  %{
                    renewed: [%{athanor: @athanor, server: "b", e: 1, state: :running}],
                    unknown: []
                  }},
               runs: [id]
             }
    end

    test "a held retire and list hold no renewal: B renewed, a sweep past B's earlier lease, " <>
           "B's session running, and another change of the home conflict",
         ctx do
      owners = start_owners(ctx)
      assert {:ok, _} = sync(owners, "a", {1, 1}, [program("kept", @idle, home: :kept)])
      assert {:ok, _} = sync(owners, "b", {1, 1}, idle_programs(1))
      assert {:ok, %{session: id}} = open(owners, "b", {1, 1}, "b1")
      test = self()
      Agent.update(ctx.stub, &Map.put(&1, :home_held, test))

      retire = %{type: :home, op: :retire, athanor: @athanor, home_id: @home}
      retiring = Task.async(fn -> control(owners, 1, retire) end)
      assert_receive {:home_held, :home_retire, retire_held}, 2_000
      listing = Task.async(fn -> control(owners, 1, %{type: :homes}) end)

      list_held =
        receive do
          {:home_held, :home_list, pid} -> pid
        after
          2_000 -> :waits
        end

      again = at_once(fn -> control(owners, 1, %{retire | op: :reset}) end)

      # Inside B's lease, then past the one it had.
      advance(ctx, 20_000)
      renew = %{type: :renew, lease_ms: 30_000, owners: [%{athanor: @athanor, server: "b", e: 1}]}
      renewed = at_once(fn -> control(owners, 1, renew) end)
      advance(ctx, 11_000)
      :ok = Owners.sweep(owners)
      runs = running_in(owners, "b")

      send(retire_held, :go)
      if is_pid(list_held), do: send(list_held, :go)

      assert %{
               list_held: is_pid(list_held),
               again: again,
               renewed: renewed,
               runs: runs,
               retired: Task.await(retiring, 5_000),
               listed: Task.await(listing, 5_000)
             } == %{
               list_held: true,
               again: {:error, :conflict},
               renewed:
                 {:ok,
                  %{
                    renewed: [%{athanor: @athanor, server: "b", e: 1, state: :running}],
                    unknown: []
                  }},
               runs: [id],
               retired: {:ok, %{home_id: @home, state: :absent}},
               listed: {:ok, %{homes: []}}
             }
    end

    test "a home change the launcher refuses for a make in flight is conflict, any other " <>
           "failure unavailable",
         ctx do
      owners = start_owners(ctx)
      assert {:ok, _} = sync(owners, "a", {1, 1}, [program("kept", @idle, home: :kept)])
      reset = %{type: :home, op: :reset, athanor: @athanor, home_id: @home}

      answers =
        for refusal <- [
              {:refused, "conflict"},
              {:refused, "internal"},
              {:launcher_unavailable, :timeout}
            ] do
          Agent.update(ctx.stub, &Map.put(&1, :home_change, {:error, refusal}))
          control(owners, 1, reset)
        end

      assert answers == [{:error, :conflict}, {:error, :unavailable}, {:error, :unavailable}]
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

      assert {:ok, _body} =
               LocusBackends.encode_answer(:status, %{owners: [owner]})
    end
  end

  describe "a key's one process" do
    @mib 1_048_576

    # The launcher of a session's process held, so nothing of its release
    # is told until the test lets it go.
    defp hold_release(owners, server, version, id) do
      backend = session_pid(owners, server, version, id)
      handle = :sys.get_state(backend).handle

      on_exit(fn ->
        try do
          :sys.resume(handle.server)
        catch
          :exit, _ -> :ok
        end
      end)

      :sys.suspend(handle.server)
      {backend, handle}
    end

    defp sessions_of(owners, server),
      do: for({_id, %{server: ^server} = o} <- held(owners), {sid, _} <- o.sessions, do: sid)

    defp holding(owners), do: map_size(:sys.get_state(owners).held)

    test "an open of a key whose last process is still going starts once nothing of it is left, after what it wrote on its way out",
         ctx do
      late = Path.join(ctx.root, "late")
      owners = start_owners(ctx, stop_grace_ms: 2_000)

      writer =
        program(
          "writer",
          "trap 'sleep 0.3; echo late > #{late}; exit 0' TERM; echo up; while :; do sleep 0.05; done; :"
        )

      assert {:ok, _} = sync(owners, "a", {1, 1}, [writer])
      assert {:ok, %{session: first, resumed: false}} = open(owners, "a", {1, 1}, "writer")
      pid = session_pid(owners, "a", {1, 1}, first)
      assert lines(pid, 1) == ["up"]

      :ok = Backend.close(pid)
      refute File.exists?(late)

      assert {:ok, %{session: next, resumed: false}} = open(owners, "a", {1, 1}, "writer")
      assert next != first
      assert File.read!(late) == "late\n"
    end

    # Two opens of one key prepared at once: the first starts its process,
    # which is closed, and the second ends its preparation while that
    # process still runs.
    defp prepared_pair(ctx, owners) do
      set_pool(ctx, {:held, self(), pool(4)})
      first = Task.async(fn -> open(owners, "a", {1, 1}, "b1") end)
      assert_receive {:pool_read, first_read}, 2_000
      second = Task.async(fn -> open(owners, "a", {1, 1}, "b1") end)
      assert_receive {:pool_read, second_read}, 2_000
      send(first_read, :answer)
      assert {:ok, %{session: id, resumed: false}} = Task.await(first)
      {id, second, second_read}
    end

    defp ended?(owners, id),
      do: Enum.any?(held(owners), fn {_id, o} -> match?(%{running: false}, o.sessions[id]) end)

    test "an open prepared while its key's process began ending waits for that process too",
         ctx do
      owners = start_owners(ctx, pool_timeout_ms: 10_000)
      assert {:ok, _} = sync(owners, "a", {1, 1}, idle_programs(1))
      {id, second, second_read} = prepared_pair(ctx, owners)
      {backend, handle} = hold_release(owners, "a", {1, 1}, id)
      :ok = Backend.close(backend)
      wait_until(fn -> ended?(owners, id) end, 2_000)

      # Prepared, it is held, its reservation given back: only the ending
      # process holds a bound.
      send(second_read, :answer)
      wait_until(fn -> holding(owners) == 1 end, 2_000)
      assert reserved(owners) == 1
      assert sessions_of(owners, "a") == [id]
      assert File.exists?("/proc/#{handle.pid}")

      # Woken, it is opened again from the start, its pool read again.
      set_pool(ctx, pool(4))
      :sys.resume(handle.server)
      assert {:ok, %{session: next, resumed: false}} = Task.await(second, 10_000)
      assert next != id
      refute File.exists?("/proc/#{handle.pid}")
    end

    test "an open prepared while its key's session is closed and released starts once, as before",
         ctx do
      owners = start_owners(ctx, pool_timeout_ms: 10_000)
      assert {:ok, _} = sync(owners, "a", {1, 1}, idle_programs(1))
      {id, second, second_read} = prepared_pair(ctx, owners)
      :ok = Backend.close(session_pid(owners, "a", {1, 1}, id))
      wait_until(fn -> reserved(owners) == 1 end, 10_000)

      send(second_read, :answer)
      assert {:ok, %{session: next, resumed: false}} = Task.await(second, 10_000)
      assert next != id
      assert holding(owners) == 0
      assert %{programs: [%{sessions: 1}]} = status(owners, "a")
    end

    test "a close refuses its lifetime's open still being prepared, waits for that work and starts nothing",
         ctx do
      owners = start_owners(ctx)
      assert {:ok, _} = sync(owners, "a", {1, 1}, idle_programs(1))
      set_pool(ctx, {:held, self(), pool(4)})
      lifetime = lifetime()
      opening = Task.async(fn -> open(owners, "a", {1, 1}, "b1", lifetime: lifetime) end)
      assert_receive {:pool_read, reading}, 2_000

      named = %{program: "b1", home_id: nil, key: "k", mode: :run, lifetime: lifetime}
      closing = Task.async(fn -> Owners.close(owners, invoke("a", {1, 1}), named) end)
      assert Task.yield(closing, 250) == nil
      assert reserved(owners) == 1

      send(reading, :answer)
      assert {:error, :lifetime_over} = Task.await(opening, 10_000)
      assert :ok = Task.await(closing, 5_000)
      assert reserved(owners) == 0
      assert sessions_of(owners, "a") == []
    end

    test "a close refuses its lifetime's open held for the key, and ends nothing of the process it waits for",
         ctx do
      owners = start_owners(ctx)
      assert {:ok, _} = sync(owners, "a", {1, 1}, idle_programs(1))
      assert {:ok, %{session: id}} = open(owners, "a", {1, 1}, "b1")
      lifetime = lifetime()
      waiting = Task.async(fn -> open(owners, "a", {1, 1}, "b1", lifetime: lifetime) end)
      wait_until(fn -> holding(owners) == 1 end, 5_000)

      named = %{program: "b1", home_id: nil, key: "k", mode: :run, lifetime: lifetime}
      assert :ok = Owners.close(owners, invoke("a", {1, 1}), named)
      assert {:error, :lifetime_over} = Task.await(waiting, 5_000)
      assert %{programs: [%{sessions: 1}]} = status(owners, "a")
      assert sessions_of(owners, "a") == [id]
    end

    test "two opens of one lifetime held for a key and woken by the same release start one process",
         ctx do
      owners = start_owners(ctx)
      assert {:ok, _} = sync(owners, "a", {1, 1}, idle_programs(1))
      assert {:ok, %{session: id}} = open(owners, "a", {1, 1}, "b1")
      {backend, handle} = hold_release(owners, "a", {1, 1}, id)
      :ok = Backend.close(backend)

      one = [lifetime: lifetime()]
      tasks = for _ <- 1..2, do: Task.async(fn -> open(owners, "a", {1, 1}, "b1", one) end)
      wait_until(fn -> holding(owners) == 2 end, 5_000)

      :sys.resume(handle.server)
      answers = Enum.map(tasks, &Task.await(&1, 10_000))

      assert [{:ok, %{session: next, resumed: false}}, {:ok, %{session: next, resumed: true}}] =
               Enum.sort_by(answers, fn {:ok, answer} -> answer.resumed end)

      assert next != id
      assert sessions_of(owners, "a") |> Enum.sort() == Enum.sort([id, next])
      assert %{programs: [%{sessions: 1}]} = status(owners, "a")
    end

    test "at its athanor's ceiling, an open of a key whose last process is ending is held, not refused",
         ctx do
      owners = start_owners(ctx)

      assert {:ok, _} =
               sync(owners, "a", {1, 1}, idle_programs(1), athanor_memory_bytes: 384 * @mib)

      assert {:ok, %{session: id}} = open(owners, "a", {1, 1}, "b1")
      {backend, handle} = hold_release(owners, "a", {1, 1}, id)
      :ok = Backend.close(backend)

      task = Task.async(fn -> open(owners, "a", {1, 1}, "b1") end)
      wait_until(fn -> holding(owners) == 1 end, 5_000)

      :sys.resume(handle.server)
      assert {:ok, %{session: next, resumed: false}} = Task.await(task, 10_000)
      assert next != id
    end

    test "a key whose last process outlives its release bound starts nothing until the launcher says it is gone",
         ctx do
      owners =
        start_owners(ctx,
          stop_grace_ms: 0,
          session_opts: [
            launcher: Locus.DirectLauncher,
            launcher_server: [kept_root: ctx.root],
            release_timeout_ms: 25
          ]
        )

      assert {:ok, _} = sync(owners, "a", {1, 1}, idle_programs(1))
      assert {:ok, %{session: id}} = open(owners, "a", {1, 1}, "b1")
      {backend, handle} = hold_release(owners, "a", {1, 1}, id)

      :erlang.trace(backend, true, [:receive])
      :ok = Backend.close(backend)
      assert_receive {:trace, ^backend, :receive, :release_timeout}, 2_000
      :erlang.trace(backend, false, [:receive])

      # Held to the grace and the release bound, then refused, with nothing
      # started and the process still there.
      assert {:error, :unavailable} = open(owners, "a", {1, 1}, "b1")
      assert File.exists?("/proc/#{handle.pid}")
      assert sessions_of(owners, "a") == [id]
      assert holding(owners) == 0

      :sys.resume(handle.server)
      wait_until(fn -> reserved(owners) == 0 end, 10_000)
      assert {:ok, %{session: next, resumed: false}} = open(owners, "a", {1, 1}, "b1")
      assert next != id
    end

    test "an open waits for its own key's last process alone: the row's other keys run and open meanwhile",
         ctx do
      owners = start_owners(ctx)
      assert {:ok, _} = sync(owners, "a", {1, 1}, idle_programs(1))
      assert {:ok, %{session: k}} = open(owners, "a", {1, 1}, "b1", key: "k")
      same = [key: "j", lifetime: lifetime()]
      assert {:ok, %{session: j}} = open(owners, "a", {1, 1}, "b1", same)
      {backend, handle} = hold_release(owners, "a", {1, 1}, k)
      :ok = Backend.close(backend)

      task = Task.async(fn -> open(owners, "a", {1, 1}, "b1", key: "k") end)
      wait_until(fn -> holding(owners) == 1 end, 5_000)

      assert {:ok, %{session: ^j, resumed: true}} = open(owners, "a", {1, 1}, "b1", same)
      assert {:ok, %{resumed: false}} = open(owners, "a", {1, 1}, "b1", key: "m")
      assert Task.yield(task, 0) == nil
      assert File.exists?("/proc/#{handle.pid}")

      :sys.resume(handle.server)
      assert {:ok, %{session: again, resumed: false}} = Task.await(task, 10_000)
      refute again in [k, j]
      refute File.exists?("/proc/#{handle.pid}")
    end

    test "a key's last process that outlived its owner's retirement holds back the key's open at the next epoch",
         ctx do
      owners =
        start_owners(ctx,
          stop_grace_ms: 0,
          session_opts: [
            launcher: Locus.DirectLauncher,
            launcher_server: [kept_root: ctx.root],
            release_timeout_ms: 25
          ]
        )

      assert {:ok, _} = sync(owners, "a", {1, 1}, idle_programs(1))
      assert {:ok, %{session: id}} = open(owners, "a", {1, 1}, "b1")
      {_backend, handle} = hold_release(owners, "a", {1, 1}, id)

      # The row's change retires the owner; its drain gives up on the
      # release at its bound, and the process is an ending no owner follows.
      assert {:ok, _} = sync(owners, "a", {1, 2}, idle_programs(1))
      wait_until(fn -> map_size(held(owners)) == 1 end, 5_000)
      assert File.exists?("/proc/#{handle.pid}")

      assert {:error, :unavailable} = open(owners, "a", {1, 2}, "b1")
      assert sessions_of(owners, "a") == []

      :sys.resume(handle.server)
      wait_until(fn -> reserved(owners) == 0 end, 10_000)
      assert {:ok, %{resumed: false}} = open(owners, "a", {1, 2}, "b1")
    end

    test "a held open holds nothing, and is opened from the start when woken: its place names the ceiling of then",
         ctx do
      owners = start_owners(ctx, session_opts: placing(ctx))
      programs = idle_programs(1)
      assert {:ok, _} = sync(owners, "a", {1, 1}, programs, athanor_memory_bytes: 768 * @mib)
      assert {:ok, %{session: k}} = open(owners, "a", {1, 1}, "b1", key: "k")
      assert_received {:placed, ^k, %{athanor_max_bytes: 805_306_368}, ^owners}
      {backend, handle} = hold_release(owners, "a", {1, 1}, k)
      :ok = Backend.close(backend)

      task = Task.async(fn -> open(owners, "a", {1, 1}, "b1", key: "k") end)
      wait_until(fn -> holding(owners) == 1 end, 5_000)

      # The held open reserves nothing and has no place yet: another key's
      # open beside the ending process is the only new one.
      assert reserved(owners) == 1
      refute_received {:placed, _id, _whose, _owner}
      assert {:ok, %{resumed: false}} = open(owners, "a", {1, 1}, "b1", key: "m")
      assert_received {:placed, _m, _whose, ^owners}
      assert reserved(owners) == 2

      assert {:ok, _} = sync(owners, "a", {1, 1}, programs, athanor_memory_bytes: 384 * @mib)
      :sys.resume(handle.server)
      assert {:ok, %{session: woken, resumed: false}} = Task.await(task, 10_000)
      assert_receive {:placed, ^woken, %{athanor_max_bytes: 402_653_184}, ^owners}, 5_000
      assert reserved(owners) == 2
    end

    test "a held open whose caller exits is withdrawn: nothing starts for it", ctx do
      owners = start_owners(ctx)
      assert {:ok, _} = sync(owners, "a", {1, 1}, idle_programs(1))
      assert {:ok, %{session: id}} = open(owners, "a", {1, 1}, "b1")
      {backend, handle} = hold_release(owners, "a", {1, 1}, id)
      :ok = Backend.close(backend)

      caller = spawn(fn -> open(owners, "a", {1, 1}, "b1") end)
      wait_until(fn -> holding(owners) == 1 end, 5_000)
      Process.exit(caller, :kill)
      wait_until(fn -> holding(owners) == 0 end, 5_000)

      :sys.resume(handle.server)
      wait_until(fn -> reserved(owners) == 0 end, 10_000)
      assert sessions_of(owners, "a") == [id]
      assert %{programs: [%{sessions: 0}]} = status(owners, "a")
    end

    test "a held open of an owner released meanwhile is refused as an open of it is, at once",
         ctx do
      owners = start_owners(ctx)
      assert {:ok, _} = sync(owners, "a", {1, 1}, idle_programs(1))
      assert {:ok, %{session: id}} = open(owners, "a", {1, 1}, "b1")
      {backend, _handle} = hold_release(owners, "a", {1, 1}, id)
      :ok = Backend.close(backend)

      task = Task.async(fn -> open(owners, "a", {1, 1}, "b1") end)
      wait_until(fn -> holding(owners) == 1 end, 5_000)

      assert {:ok, %{released: [_]}} =
               control(owners, 1, %{
                 type: :release,
                 owners: [%{athanor: @athanor, server: "a", e: 1}]
               })

      # Well inside the hold's bound (the grace and the release bound).
      assert Task.await(task, 2_000) == {:error, :unknown_owner}
      assert holding(owners) == 0
    end

    test "a process adopted under a tag that names no row or key holds back no open", ctx do
      owners =
        start_owners(ctx,
          session_opts: [
            launcher: OldTags,
            launcher_server: [kept_root: ctx.root],
            release_timeout_ms: 5_000
          ]
        )

      assert reserved(owners) == 1
      assert {:ok, _} = sync(owners, "a", {1, 1}, idle_programs(1))
      assert {:ok, %{resumed: false}} = open(owners, "a", {1, 1}, "b1")
      assert reserved(owners) == 2
      assert Process.alive?(owners)
    end
  end
end
