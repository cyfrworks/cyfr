# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.KeeperTest do
  @moduledoc """
  The client side of cyfr-locus's protocol. Against a fake keeper
  (`Locus.Test.FakeKeeper`): a run delivers stdin, answers stdout, the
  log line by line and the exit, and returns only after the spawn is
  reported released; the deadline, a stdout bound, a cancel and the
  caller's death release the spawn with no grace; a relay connection
  that arrives after the client has read the exit and release reports
  still delivers its output, and one that arrives after a cancel is closed
  as it attaches, the run ending at the release; a spawn refused before
  the keeper made it and a lost channel answer at once, one refused after
  the keeper made it once the keeper reports it released; a spawn ended
  at its bound is the wire's `memory` refusal and a bound that cannot be
  enforced its `unavailable`, naming the option the deployment lacks. A long-lived spawn (`Locus.Launcher`) answers
  its handle, and its owner hears the relay attached, its stdout and
  stderr apart and its exit, then its release, the last; stdin goes as
  frames of the codec's bound; `signal`, `release` with a grace and
  `pool` are the vectors' requests, byte for byte but for their own ids;
  a spawn refused after the keeper made it is refused at once, and its
  heir and owner hear its release once, at the keeper's `released`; a
  lost channel tells its owner so, and neither it nor its heir that it is
  released;
  an owner that dies has its spawn released with no grace; a request the
  keeper would refuse is refused before it is sent. A place is the
  vectors' request, answered once the keeper placed it, and refused
  without a request while the client still follows its id; one whose
  owner dies before a spawn names it is dropped, while placing too, and
  one a spawn named is the spawn's until its release; a drop frees only a
  place no spawn named, an assign changes whose a place is, and a spawn
  refused before the keeper made it frees its place. A measure names a place and answers the keeper's
  reading with whose the place is and its age, or `unmeasured` for a
  place the keeper does not hold or has not read. No credential leaves
  the client: a runner's held assign, a frame not yet whole and every
  message carrying a payload show no key or environment value in a
  status or a crash report, a crash report names the reason the client
  stopped by its kind alone, and a call to a client that is gone, or a
  run whose client crashed, answers the failure by its kind alone. A
  runner's relay that stops reading is closed once a write to it waits
  out the 5 s bound, and its owner hears its control channel and relay
  closed. The spawns' vectors are `Locus.KeeperVectorsTest`'s, and the
  cases that change the application or process environment
  `Locus.KeeperEnvTest`'s. Whether a real spawn's space holds is the image
  tests' to prove.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Prima.Test.Wait

  alias Locus.Keeper
  alias Locus.Runtime.Test.ScriptedHost
  alias Locus.Test.FakeKeeper
  alias Prima.KeeperProtocol

  @vectors Path.expand("../../../../tests/fixtures/keeper_protocol.json", __DIR__)
           |> File.read!()
           |> Jason.decode!()

  # A place made for the calling process against the fake keeper, under an
  # id new to the run, as every spawn's is before it is asked for.
  defp place!(name, kind \\ "program") do
    id = "pl-" <> Integer.to_string(System.unique_integer([:positive]))
    assert :ok = Keeper.place(name, id, %{kind: kind}, self())
    id
  end

  # An instant a test's assign waits until for an answer that comes at once.
  defp soon, do: System.monotonic_time(:millisecond) + 5_000

  # The owner's word for an event carrying a spawn's bytes, which a session
  # or a runner's process says once it has taken them: the client reads the
  # spawn's next bytes only then.
  defp took(handle, {stream, _bytes}) when stream in [:stdout, :stderr, :control, :relay],
    do: :ok = Keeper.taken(handle)

  defp took(_handle, _event), do: :ok

  # A run's deadline, `ms` from now.
  defp within(ms), do: System.monotonic_time(:millisecond) + ms

  defp run(name, script, opts \\ []) do
    lines = Agent.start_link(fn -> [] end) |> elem(1)

    result =
      Keeper.run(
        name,
        %{
          argv: ["/bin/sh", "-c", script],
          env: %{"GREETING" => "hello"},
          stdin: Keyword.get(opts, :stdin, "")
        },
        [
          place: place!(name, "build"),
          deadline: within(Keyword.get(opts, :timeout_ms, 10_000)),
          max_stdout_bytes: Keyword.get(opts, :max_stdout_bytes, 1_000_000),
          on_stdout: {[], fn piece, taken -> {:ok, [taken, piece]} end},
          on_output: fn line -> Agent.update(lines, &[line | &1]) end
        ] ++ Keyword.take(opts, [:memory_bytes])
      )

    {stdout(result), Agent.get(lines, &Enum.reverse/1)}
  end

  # A run's stdout as the fold above took it, whole.
  defp stdout({:ok, %{exit: exit, taken: taken}}),
    do: {:ok, %{exit: exit, stdout: IO.iodata_to_binary(taken)}}

  defp stdout(result), do: result

  describe "against the fake keeper" do
    setup do
      {:ok, FakeKeeper.start_client!()}
    end

    test "a fence refuses every later spawn carrying its tag", %{name: name} do
      tag = %{
        ledger: make_ref(),
        session: {make_ref(), "ss_fenced"},
        athanor: "ath_fence",
        memory_bytes: 268_435_456,
        home_id: nil
      }

      spec = %{
        argv: ["/bin/sh", "-c", "exec cat"],
        env: %{},
        place: place!(name),
        pool: "backends",
        memory_bytes: 268_435_456,
        cpu_quota: 100_000,
        heir: {self(), tag}
      }

      assert :none = Keeper.fence(name, tag)
      first = Keeper.spawn(name, spec)
      second = Keeper.spawn(name, spec)

      case second do
        {:ok, handle} ->
          Keeper.release(name, handle, 0)
          ref = handle.ref
          assert_receive {Keeper, ^ref, :released}, 5_000

        _ ->
          :ok
      end

      assert {:error, {:spawn_failed, :fenced}} = first
      assert {:error, {:spawn_failed, :fenced}} = second
    end

    test "a bound the keeper cannot enforce is named as the memory's and the CPU's",
         %{name: name, fake: fake} do
      :ok = FakeKeeper.mode(fake, :memory_unavailable)
      assert {{:error, {:unavailable, sentence}}, []} = run(name, "true")
      runner = Locus.Runtime.Keeper.Channel.refusal(:memory_unavailable)
      assert sentence =~ "memory and CPU"
      assert runner.message =~ "memory and CPU"
    end

    defp releases(fake, grace) do
      fake
      |> FakeKeeper.requests()
      |> Enum.filter(&(&1["type"] == "release" and &1["grace_ms"] == grace))
    end

    # The releases the fake has recorded once the first reaches it: a run
    # may answer before its release is read, when the command ended on
    # its own first.
    defp awaited_releases(fake, grace) do
      wait_until(fn -> releases(fake, grace) != [] end, 5_000)
      releases(fake, grace)
    end

    test "a run delivers stdin and answers stdout, the log by line and the exit status", %{
      name: name,
      fake: fake
    } do
      stdin = :binary.copy("x", 200_000)

      {result, lines} =
        run(name, ~s(wc -c | tr -d ' '; echo "$GREETING" >&2; printf 'partial' >&2; exit 3),
          stdin: stdin
        )

      assert {:ok, %{exit: {:status, 3}, stdout: stdout}} = result
      assert String.trim(stdout) == "200000"
      assert lines == ["hello", "partial"]

      [spawn] = fake |> FakeKeeper.requests() |> Enum.filter(&(&1["type"] == "spawn"))
      assert spawn["pool"] == "build"
      assert spawn["env"] == %{"GREETING" => "hello"}
      assert spawn["attach"]["token"] =~ ~r/^[0-9a-f]{64}$/
    end

    test "a spawn ended at its memory bound answers the wire's memory refusal with the bound", %{
      name: name,
      fake: fake
    } do
      :ok =
        FakeKeeper.mode(fake, {:exit, %{code: nil, signal: "SIGKILL", memory: "cap"}})

      assert {{:error, {:memory, 33_554_432}}, ["the command's last words"]} =
               run(name, "true", memory_bytes: 33_554_432)

      # A kill for memory that is not at the bound names its cause and no bytes.
      for {spelled, cause} <- [{"machine", :machine}, {"either", :either}] do
        :ok = FakeKeeper.mode(fake, {:exit, %{code: nil, signal: "SIGKILL", memory: spelled}})
        assert {{:error, {:memory, ^cause}}, _} = run(name, "true", memory_bytes: 33_554_432)
      end

      # The same end without the kernel's report is a signal like any other.
      :ok = FakeKeeper.mode(fake, {:exit, %{code: nil, signal: "SIGKILL", memory: nil}})
      assert {{:ok, %{exit: {:signal, "SIGKILL"}}}, _} = run(name, "true")
    end

    test "a keeper that cannot enforce the bound runs nothing: unavailable, naming the option",
         %{
           name: name,
           fake: fake
         } do
      :ok = FakeKeeper.mode(fake, :memory_unavailable)

      assert {{:error, {:unavailable, sentence}}, []} = run(name, "true")
      assert sentence =~ "writable-cgroups=true"
      assert sentence =~ "Docker Engine 28"
      assert {:ok, _} = Prima.BuilderProtocol.encode_refusal({:unavailable, sentence})
    end

    test "a cancelled run releases the spawn with no grace and answers cancelled", %{
      name: name,
      fake: fake
    } do
      test = self()
      runner = spawn_link(fn -> send(test, {:answer, run(name, "exec sleep 30")}) end)
      wait_until(fn -> FakeKeeper.running(fake) != [] end, 5_000, "the command to run")

      :ok = Locus.Executor.cancel(runner)

      assert_receive {:answer, {{:error, :cancelled}, _lines}}, 10_000
      assert [_] = awaited_releases(fake, 0)
      wait_until(fn -> FakeKeeper.exits(fake) != [] end, 5_000, "the released command to end")
    end

    test "a run cancelled before its relay attaches closes the relay's connection as it attaches, and ends at the release",
         %{name: name, fake: fake} do
      test = self()
      :ok = FakeKeeper.mode(fake, {:dial_after_release, test})
      runner = spawn_link(fn -> send(test, {:answer, run(name, "exec sleep 30")}) end)
      wait_until(fn -> requests(fake, "spawn") != [] end, 5_000, "the spawn to be asked for")

      :ok = Locus.Executor.cancel(runner)

      assert_receive {:fake_relay, ended, open_ms}, 10_000

      assert {ended, open_ms < 1_000} == {:closed, true},
             "the late relay's connection was #{ended} after #{open_ms} ms"

      assert_receive {:answer, {{:error, :cancelled}, _lines}}, 10_000
      assert FakeKeeper.sent(fake) == [:dial, :exited, :released]
    end

    test "a run past its deadline releases the spawn with no grace", %{name: name, fake: fake} do
      started = System.monotonic_time(:millisecond)
      # The fake kills the command's PID; exec avoids a shell-owned child.
      {result, _lines} = run(name, "exec sleep 30", timeout_ms: 300)

      assert result == {:error, :timeout}
      assert System.monotonic_time(:millisecond) - started < 10_000
      assert [_] = awaited_releases(fake, 0)
    end

    test "stdout past its bound releases the spawn", %{name: name, fake: fake} do
      {result, _lines} = run(name, "head -c 5000 /dev/zero", max_stdout_bytes: 1_000)

      assert result == {:error, {:output_too_large, 1_000}}

      # The fake reports the command's output at its exit, so the exit report
      # and the output race: a spawn the keeper already saw end has nothing
      # to release, and one still running is released with no grace.
      wait_until(fn -> releases(fake, 0) != [] or FakeKeeper.exits(fake) != [] end, 5_000)

      if FakeKeeper.exits(fake) == [] do
        assert [_] = releases(fake, 0)
      end
    end

    test "a caller that dies has its spawn released", %{name: name, fake: fake} do
      caller = spawn(fn -> run(name, "exec sleep 30") end)
      wait_until(fn -> FakeKeeper.running(fake) != [] end, 5_000, "the command to run")
      Process.exit(caller, :kill)

      wait_until(fn -> releases(fake, 0) != [] end, 5_000)
      wait_until(fn -> FakeKeeper.exits(fake) != [] end, 5_000, "the released command to end")
    end

    test "a run reads its next frame only once its taker took the last, so the relay waits behind it",
         %{name: name, fake: fake} do
      test = self()
      bytes = :crypto.strong_rand_bytes(16 * 1_048_576)
      :ok = FakeKeeper.mode(fake, {:stdout, bytes, test})

      # The first piece is held until the test says go; every later one is
      # taken at once.
      take = fn piece, taken ->
        if taken == [] do
          send(test, {:taking, self()})
          receive do: (:go -> :ok)
        end

        {:ok, [taken, piece]}
      end

      runner =
        Task.async(fn ->
          Keeper.run(name, %{argv: ["/bin/true"], env: %{}, stdin: ""},
            place: place!(name, "build"),
            deadline: within(60_000),
            max_stdout_bytes: byte_size(bytes),
            on_stdout: {[], take}
          )
        end)

      assert_receive {:taking, taker}, 10_000

      # While the taker holds the first piece the relay is held where it
      # stands: what it could write is what the sockets hold and one read.
      {kind, sent} = quiet()
      assert kind == :sending, "the relay is blocked in a write"

      assert sent <= 4 * 1_048_576,
             "the relay wrote #{sent} bytes past a reader that took one frame"

      send(taker, :go)
      assert {:ok, %{exit: {:status, 0}, taken: taken}} = Task.await(runner, 30_000)
      assert IO.iodata_to_binary(taken) == bytes
      assert_received {:fake_relay, :ended, _sent}
    end

    test "a run whose taker is slower than its deadline closes its connection there, which cuts the relay",
         %{name: name, fake: fake} do
      test = self()
      :ok = FakeKeeper.mode(fake, {:stdout, :binary.copy(<<1>>, 8 * 1_048_576), test})

      take = fn piece, taken ->
        # sleep-ok: a taker slower than the run's deadline is the case.
        Process.sleep(1_500)
        {:ok, [taken, piece]}
      end

      result =
        Keeper.run(name, %{argv: ["/bin/true"], env: %{}, stdin: ""},
          place: place!(name, "build"),
          deadline: within(1_000),
          max_stdout_bytes: 16 * 1_048_576,
          on_stdout: {[], take}
        )

      # The run answers only after cyfr-locus's word, which follows the
      # relay's end, which the reader's close made.
      assert result == {:error, :timeout}
      assert_received {:fake_relay, :cut, _sent}
      assert FakeKeeper.sent(fake) |> Enum.take(-1) == [:released]
    end

    test "a reader that dies closes its connection by dying, which cuts the relay",
         %{name: name, fake: fake} do
      test = self()
      :ok = FakeKeeper.mode(fake, {:stdout, :binary.copy(<<1>>, 8 * 1_048_576), test})

      reader =
        spawn(fn ->
          Keeper.run(name, %{argv: ["/bin/true"], env: %{}, stdin: ""},
            place: place!(name, "build"),
            deadline: within(60_000),
            max_stdout_bytes: 16 * 1_048_576,
            on_stdout:
              {[],
               fn _piece, _taken ->
                 send(test, :taking)
                 receive do: (:never -> :ok)
               end}
          )
        end)

      assert_receive :taking, 10_000
      Process.exit(reader, :kill)

      assert_receive {:fake_relay, :cut, _sent}, 10_000
      wait_until(fn -> releases(fake, 0) != [] end, 5_000, "the dead reader's spawn released")
    end

    test "a run's heir hears its end once, at cyfr-locus's word, after its reader died, " <>
           "and a run naming a fenced tag starts nothing",
         %{name: name, fake: fake} do
      test = self()
      tag = make_ref()
      # The command runs until cyfr-locus retires it, so its end is the
      # keeper's release alone, which the fake holds.
      :ok = FakeKeeper.hold_releases(fake, test)

      reader =
        spawn(fn ->
          Keeper.run(
            name,
            %{argv: ["/bin/sh", "-c", "echo running >&2; exec sleep 300"], env: %{}, stdin: ""},
            place: place!(name, "build"),
            deadline: within(60_000),
            max_stdout_bytes: 1_048_576,
            heir: {test, tag},
            on_output: fn line -> send(test, {:run_said, line}) end
          )
        end)

      assert_receive {:run_said, "running"}, 10_000
      Process.exit(reader, :kill)

      # The keeper asks for the spawn's end, which cyfr-locus has not given.
      assert_receive {:release_held, _spawn_id}, 10_000
      assert Keeper.fence(name, tag) == :pending
      refute_received {Keeper, {:heir, ^tag}, :released}

      :ok = FakeKeeper.carry_releases(fake)
      assert_receive {Keeper, {:heir, ^tag}, :released}, 10_000
      assert Keeper.fence(name, tag) == :none
      refute_receive {Keeper, {:heir, ^tag}, :released}, 200

      assert {:error, {:spawn_failed, :fenced}} =
               Keeper.run(name, %{argv: ["/bin/true"], env: %{}, stdin: ""},
                 place: place!(name, "build"),
                 deadline: within(10_000),
                 max_stdout_bytes: 1_048_576,
                 heir: {test, tag}
               )
    end

    test "a relay that dials once the client has read the exit and release reports still delivers its output",
         %{name: name, fake: fake, client: client} do
      test = self()

      # The relay dials only once this holds: the client has taken the
      # release report while no relay is attached to the run.
      reported? = fn ->
        entries = client |> :sys.get_state() |> Map.fetch!(:requests) |> Map.values()
        seen? = Enum.any?(entries, &(&1.released and not &1.attached))
        if seen?, do: send(test, :release_seen_unattached)
        seen?
      end

      :ok = FakeKeeper.mode(fake, {:report_first, reported?})
      {result, _lines} = run(name, "echo late")

      assert FakeKeeper.sent(fake) == [:exited, :released, :dial]
      assert_received :release_seen_unattached
      assert {:ok, %{exit: {:status, 0}, stdout: "late\n"}} = result
    end

    # The channel is lost while the command runs: the relay ends before its
    # last frames, by its client's loss in report-first mode, and leaves no
    # command directory behind in either mode.
    for mode <- [:normal, :report_first] do
      @tag relay_mode: mode
      test "a relay ended by the channel's loss mid-run removes its command directory (#{mode})",
           %{name: name, fake: fake, client: client, relay_mode: mode} do
        test = self()

        if mode == :report_first do
          reported? = fn ->
            send(test, {:reporting, self()})

            client
            |> :sys.get_state()
            |> Map.fetch!(:requests)
            |> Map.values()
            |> Enum.any?(&(&1.released and not &1.attached))
          end

          :ok = FakeKeeper.mode(fake, {:report_first, reported?})
        end

        task = Task.async(fn -> run(name, "sleep 0.3; echo done", timeout_ms: 2_000) end)
        wait_until(fn -> FakeKeeper.running(fake) != [] end, 5_000, "the command to run")
        [dir] = FakeKeeper.command_dirs(fake)
        assert File.dir?(dir)

        :ok = FakeKeeper.close(fake)
        assert {{:error, _reason}, _lines} = Task.await(task, 5_000)

        if mode == :report_first do
          assert_receive {:reporting, relay}, 5_000
          monitor = Process.monitor(relay)
          assert_receive {:DOWN, ^monitor, :process, ^relay, _reason}, 5_000
          refute File.exists?(dir)
        else
          wait_until(fn -> not File.exists?(dir) end, 5_000, "the command directory to go")
        end
      end
    end

    test "a spawn the pool cannot hold is refused as capacity", %{name: name, fake: fake} do
      :ok = FakeKeeper.mode(fake, :capacity)
      assert {{:error, :capacity}, []} = run(name, "true")
    end

    test "a run whose spawn the keeper refused after making it answers its refusal only once the keeper reports it released",
         %{name: name, fake: fake, client: client} do
      :ok = FakeKeeper.mode(fake, {:exec_failed, self()})
      task = Task.async(fn -> run(name, "true") end)
      assert_receive {:exec_failed, spawn_id}, 5_000

      # The client has heard the refusal, and the run's caller with it.
      wait_until(fn -> Map.has_key?(:sys.get_state(client).spawns, spawn_id) end, 5_000)
      assert Task.yield(task, 500) == nil

      :ok = FakeKeeper.released(fake, spawn_id)
      assert {{:error, {:spawn_failed, "exec_failed"}}, []} = Task.await(task, 5_000)
      assert requests(fake, "release") == []
    end

    test "losing the channel ends the client and answers a waiting run", %{
      name: name,
      fake: fake,
      client: client
    } do
      ref = Process.monitor(client)
      task = Task.async(fn -> run(name, "exec sleep 30") end)
      wait_until(fn -> Enum.any?(FakeKeeper.requests(fake), &(&1["type"] == "spawn")) end, 5_000)

      :ok = FakeKeeper.close(fake)

      assert {{:error, _reason}, _lines} = Task.await(task, 10_000)
      assert_receive {:DOWN, ^ref, :process, ^client, {:shutdown, :channel_lost}}, 5_000
    end

    test "a connection presenting an unknown token is closed", %{client: client} do
      path = :sys.get_state(client).attach_path
      {:ok, conn} = :gen_tcp.connect({:local, path}, 0, [:binary, active: false])
      :ok = :gen_tcp.send(conn, [<<3, 64::32>>, String.duplicate("ab", 32)])
      assert {:error, :closed} = :gen_tcp.recv(conn, 0, 5_000)
    end

    test "an attach directory others can enter is refused" do
      Process.flag(:trap_exit, true)
      dir = FakeKeeper.short_tmp_dir()
      {fake, channel} = FakeKeeper.start()

      on_exit(fn ->
        Process.exit(fake, :kill)
        File.rm_rf!(dir)
      end)

      File.chmod!(dir, 0o755)

      assert {:error, {:keeper_unavailable, {:attach_dir_not_private, ^dir}}} =
               Keeper.start_link(channel: channel, attach_dir: dir, name: :keeper_open_dir)
    end

    # The role's run folder is at the same path inside its space and
    # outside it, where cyfr-locus starts the relays: a client listens there
    # unless told another directory.
    test "the attach directory is the run folder cyfr-locus names, or /run/locus" do
      assert Keeper.default_attach_dir(fn "KEEPER_RUN_DIR" -> "/run/locus/builds" end) ==
               "/run/locus/builds"

      assert Keeper.default_attach_dir(fn "KEEPER_RUN_DIR" -> nil end) == "/run/locus"
      assert Keeper.default_attach_dir(fn "KEEPER_RUN_DIR" -> "" end) == "/run/locus"
    end
  end

  describe "no credential on an exit path" do
    # A key planted as an assign's call and seal keys, and a secret as a
    # spawn's environment value: a status, a crash report's message, an
    # answer or a log line is clean when none of the key, its lowercase hex
    # or the secret occurs in it.
    defp plant do
      key = :crypto.strong_rand_bytes(32)
      secret = "planted-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
      attempt = ScriptedHost.attempt!(ScriptedHost.start!())
      keys = %{attempt.keys | call: key, seal: key}

      assign =
        %{type: :assign, assignment: attempt.assignment, input: "{}", keys: keys}
        |> Prima.RunnerControl.encode()
        |> IO.iodata_to_binary()

      %{
        key: key,
        secret: secret,
        assign: assign,
        env: %{"RUNTIME_ROLE" => "runner", "RUNTIME_PLANT" => secret}
      }
    end

    defp clean?(plant, text) when is_binary(text) do
      Enum.all?(
        [plant.key, Base.encode16(plant.key, case: :lower), plant.secret],
        &(:binary.match(text, &1) == :nomatch)
      )
    end

    defp clean?(plant, term), do: clean?(plant, :erlang.term_to_binary(term))

    # A client on a channel whose far end the test holds.
    defp plain_client! do
      {peer, channel} = channel_pair()
      attach_dir = FakeKeeper.short_tmp_dir()
      {:ok, client} = Keeper.start_link(channel: channel, attach_dir: attach_dir, name: nil)
      Process.unlink(client)
      :ok = :socket.setopt(channel, {:otp, :controlling_process}, client)

      on_exit(fn ->
        Process.exit(client, :kill)
        File.rm_rf!(attach_dir)
      end)

      %{peer: peer, name: client, client: client, attach_dir: attach_dir}
    end

    defp channel_pair do
      dir = FakeKeeper.short_tmp_dir()
      path = Path.join(dir, "channel.sock")
      {:ok, listener} = :socket.open(:local, :stream)
      :ok = :socket.bind(listener, %{family: :local, path: path})
      :ok = :socket.listen(listener)
      {:ok, client} = :socket.open(:local, :stream)
      :ok = :socket.connect(client, %{family: :local, path: path})
      {:ok, ours} = :socket.accept(listener)
      :socket.close(listener)
      File.rm_rf!(dir)
      {ours, client}
    end

    defp request(peer, buffer \\ "") do
      case :binary.split(buffer, "\n") do
        [line, _rest] ->
          Jason.decode!(line)

        [partial] ->
          {:ok, data} = :socket.recv(peer, 0, 5_000)
          request(peer, partial <> data)
      end
    end

    # The place `id` made for this process on a client whose channel's far
    # end the test holds, answered as cyfr-locus answers it.
    defp placed!(c, id) do
      owner = self()
      task = Task.async(fn -> Keeper.place(c.name, id, %{kind: "warm"}, owner) end)
      assert %{"type" => "place", "id" => ^id} = request(c.peer)
      :ok = :socket.send(c.peer, [Jason.encode!(%{v: 5, type: "placed", id: id}), ?\n])
      assert :ok = Task.await(task)
    end

    test "(a) a runner's held assign, its partial frames and every payload message show no key or environment value" do
      p = plant()
      c = plain_client!()

      adapter =
        start_supervised!(
          {Locus.Runtime.Keeper.Channel,
           client: c.name, memory_bytes: 268_435_456, cpu_quota: 100_000, name: nil}
        )

      # The runtime's adapter asks for the runner, as a runner's process
      # does, with the planted environment.
      spec = %{
        runner: "runner_plant",
        argv: ["/app/bin/locus", "start"],
        env: p.env,
        server: adapter
      }

      placed!(c, "runner_plant")
      assert {:ok, channel, []} = Locus.Runtime.Keeper.Channel.spawn(spec)
      %{"id" => id, "attach" => %{"token" => token}} = request(c.peer)
      spawn_id = String.duplicate("ab", 16)

      :ok =
        :socket.send(c.peer, [
          Jason.encode!(%{v: 5, type: "spawned", id: id, spawn_id: spawn_id, uid: 1, pid: 1}),
          ?\n
        ])

      assert_receive {Keeper, _ref, {:spawned, ^spawn_id, 1, 1}}, 5_000

      # The assign, sent before the relay attaches, is held, and answered
      # once the attached connection has written it.
      sending = Task.async(fn -> Locus.Runtime.Keeper.Channel.send(channel, p.assign) end)

      wait_until(
        fn ->
          Enum.any?(:sys.get_state(c.client).requests, fn {_ref, entry} -> entry.pending != [] end)
        end,
        5_000
      )

      for process <- [c.client, adapter],
          do: assert(clean?(p, :sys.get_status(process)), "#{inspect(process)} shows the assign")

      # A frame of the control stream not yet whole, carrying the key.
      {:ok, relay} =
        :gen_tcp.connect({:local, Path.join(c.attach_dir, "attach.sock")}, 0, [
          :binary,
          active: false
        ])

      :ok = :gen_tcp.send(relay, Prima.KeeperProtocol.attach_frame(token))
      assert_receive {Keeper, _ref, :attached}, 5_000
      assert :ok = Task.await(sending)
      hex = Base.encode16(p.key, case: :lower)
      :ok = :gen_tcp.send(relay, [<<4, 4_000::32>>, ~s({"keys":{"call":"#{hex}")])

      wait_until(
        fn ->
          Enum.any?(:sys.get_state(c.client).requests, fn {_ref, entry} -> entry.frames != "" end)
        end,
        5_000
      )

      assert clean?(p, :sys.get_status(c.client)), "the status shows a partial frame"

      # Every message that carries a payload, as a crash report shows it.
      {:ok, port} = :gen_tcp.listen(0, [])
      on_exit(fn -> :gen_tcp.close(port) end)
      ref = channel.ref

      for message <- [
            {:tcp, port, p.assign},
            {:stdin, ref, p.assign},
            {:control, ref, p.assign},
            {:relay, ref, p.assign},
            {:spawn, ["/app/bin/locus", "start"], p.env,
             %{memory_bytes: 268_435_456, cpu_quota: 100_000}},
            {:spawn_handle, ref, ["/app/bin/locus", "start"], p.env,
             %{
               pool: "runner",
               memory_bytes: 268_435_456,
               cpu_quota: 100_000,
               control: true
             }}
          ] do
        status =
          Keeper.format_status(%{message: message, state: :sys.get_state(c.client), log: []})

        assert clean?(p, status), "format_status shows #{inspect(elem(message, 0))}'s payload"
      end

      assert %{message: {:attach, :redacted}} =
               Keeper.format_status(%{message: {:attach, token}})

      :gen_tcp.close(relay)
    end

    test "(b) a call to a client that is gone answers its kind alone" do
      p = plant()
      gone = %{ref: make_ref(), server: :no_such_keeper_client}

      spawned =
        Locus.Runtime.Keeper.Channel.spawn(%{
          runner: "runner_plant",
          argv: ["/app/bin/locus", "start"],
          env: p.env,
          server: :no_such_runtime_adapter
        })

      sent = Locus.Runtime.Keeper.Channel.send(gone, p.assign)
      relayed = Locus.Runtime.Keeper.Channel.send_relay(gone, p.assign)

      run =
        Keeper.run(
          :no_such_keeper_client,
          %{argv: ["/bin/true"], env: p.env, stdin: p.assign},
          place: "pl-gone",
          deadline: within(1_000),
          max_stdout_bytes: 1_000
        )

      launched =
        Keeper.spawn(:no_such_keeper_client, %{
          argv: ["/bin/true"],
          env: p.env,
          place: "pl-gone",
          pool: "runner",
          memory_bytes: 268_435_456,
          cpu_quota: 100_000
        })

      answers = [spawned, sent, relayed, run, launched, Keeper.send_control(gone, p.assign)]
      for answer <- answers, do: assert(clean?(p, answer), "#{inspect(answer)} carries a payload")

      assert spawned == {:error, {:keeper_unavailable, :noproc}}
      assert sent == {:error, {:keeper_unavailable, :noproc}}
      assert relayed == {:error, {:keeper_unavailable, :noproc}}
      assert run == {:error, {:spawn_failed, {:keeper_unavailable, :noproc}}}
      assert launched == {:error, {:launcher_unavailable, :noproc}}
    end

    test "(b) a run whose client crashes answers the crash by its kind alone" do
      p = plant()
      c = plain_client!()
      placed!(c, "pl-crash")

      task =
        Task.async(fn ->
          Keeper.run(c.name, %{argv: ["/bin/true"], env: p.env, stdin: p.assign},
            place: "pl-crash",
            deadline: within(10_000),
            max_stdout_bytes: 1_000
          )
        end)

      assert %{"type" => "spawn"} = request(c.peer)

      # The termination is asynchronous, and the client writes its crash
      # report before it exits, so the report is whole once it is down.
      log =
        capture_log(fn ->
          down = Process.monitor(c.client)
          :sys.terminate(c.client, {:crashed_holding, p.secret, p.assign})
          assert_receive {:DOWN, ^down, :process, _, _}, 5_000
        end)

      assert {:error, {:spawn_failed, {:keeper_down, :crashed}}} = answer = Task.await(task)
      assert clean?(p, answer)

      assert log =~ "#{inspect(c.name)} terminating"
      assert clean?(p, log), "the crash report shows its stop reason's payload:\n#{log}"
      assert log =~ "** (stop) :crashed"
    end

    test "a crash report names the reason the client stopped by its kind alone" do
      p = plant()
      raised = %RuntimeError{message: p.secret <> p.assign}
      stack = [{Keeper, :handle_info, [{:control, make_ref(), p.assign}, %{}], []}]

      for {reason, kind} <- [
            {:normal, :normal},
            {:killed, :killed},
            {{:shutdown, {:held, p.secret, p.assign}}, :shutdown},
            {{raised, stack}, RuntimeError},
            {raised, RuntimeError},
            {{:crashed_holding, p.secret, p.assign}, :crashed},
            {{p.secret, stack}, :crashed},
            {p.assign, :crashed}
          ] do
        assert Keeper.format_status(%{reason: reason}) == %{reason: kind},
               "#{inspect(kind)}'s form is not named by its kind"
      end
    end
  end

  describe "a runner's spawn" do
    # A runner spawned and attached on a client whose channel's far end the
    # test holds, its relay's opening frame read: its handle and the relay.
    defp attached_runner!(c) do
      placed!(c, "runner_attached")

      assert {:ok, %{ref: ref} = handle} =
               Keeper.spawn(c.name, %{
                 argv: ["/app/bin/locus", "start"],
                 env: %{},
                 place: "runner_attached",
                 pool: "runner",
                 memory_bytes: 268_435_456,
                 cpu_quota: 100_000,
                 control: true
               })

      %{"id" => id, "attach" => %{"token" => token}} = request(c.peer)
      spawn_id = String.duplicate("cd", 16)

      spawned = %{v: 5, type: "spawned", id: id, spawn_id: spawn_id, uid: 1, pid: 1}
      :ok = :socket.send(c.peer, [Jason.encode!(spawned), ?\n])
      assert_receive {Keeper, ^ref, {:spawned, ^spawn_id, 1, 1}}, 5_000

      {:ok, relay} =
        :gen_tcp.connect({:local, Path.join(c.attach_dir, "attach.sock")}, 0, [
          :binary,
          active: false
        ])

      :ok = :gen_tcp.send(relay, KeeperProtocol.attach_frame(token))
      assert_receive {Keeper, ^ref, :attached}, 5_000
      assert {:ok, <<5, 0::32>>} = :gen_tcp.recv(relay, 5, 5_000)
      {handle, relay}
    end

    # Every event of `handle` until a second passes with none, in order,
    # each of the runner's bytes taken as its owner takes them.
    defp heard(%{ref: ref} = handle, acc \\ []) do
      receive do
        {Keeper, ^ref, event} ->
          took(handle, event)
          heard(handle, [event | acc])
      after
        1_000 -> Enum.reverse(acc)
      end
    end

    # The process writing to `handle`'s connection: its writer.
    defp writer!(c, %{ref: ref}), do: :sys.get_state(c.client).requests[ref].writer

    defp queued_at_least(pid, n) do
      wait_until(fn -> elem(Process.info(pid, :message_queue_len), 1) >= n end, 5_000)
    end

    # A process waiting for a write to a connection that does not take it:
    # suspended on the busy port, or waiting for the driver's reply.
    defp writing?(pid) do
      case Process.info(pid, [:status, :current_function]) do
        [status: :suspended, current_function: _function] -> true
        [status: _status, current_function: {:prim_inet, _name, _arity}] -> true
        _other -> false
      end
    end

    # One server holds every spawn's connection on the node: a runner whose
    # relay stops reading is closed once a write to it waits out its bound,
    # and the server goes on serving the rest.
    @tag timeout: 60_000
    test "a relay that stops reading is closed at the write bound, and its owner hears so" do
      c = plain_client!()
      {%{ref: ref} = handle, relay} = attached_runner!(c)

      # The relay reads nothing: the connection's buffers fill, and a write
      # waits out the bound.
      chunk = :binary.copy("x", KeeperProtocol.max_frame_bytes())
      started = System.monotonic_time(:millisecond)

      assert {:error, :timeout} =
               Stream.repeatedly(fn -> Keeper.send_control(handle, chunk) end)
               |> Enum.find(&(&1 != :ok))

      assert System.monotonic_time(:millisecond) - started >= 5_000
      assert_receive {Keeper, ^ref, :control_closed}, 5_000
      assert_receive {Keeper, ^ref, :relay_closed}, 5_000
      assert {:error, :control_closed} = Keeper.send_control(handle, "more")
      assert {:error, :relay_closed} = Keeper.send_relay(handle, "more")
      assert :sys.get_state(c.client).conns == %{}
      :gen_tcp.close(relay)
    end

    # A failed write closes the connection, but never before what it
    # already carried reaches the owner.
    test "a runner's last control frame reaches its owner before the close a failed write finds" do
      c = plain_client!()
      {handle, relay} = attached_runner!(c)

      # The service writes to the runner while the runner, having written
      # its last control line, closes its end; the client hears the line
      # only after the write, and the close once the line is taken, since
      # it reads a held connection one read at a time.
      :ok = :sys.suspend(c.client)
      writer = Task.async(fn -> Keeper.send_control(handle, ~s({"type":"cancel_child"}\n)) end)
      queued_at_least(c.client, 1)
      last = ~s({"type":"complete"}\n)
      :ok = :gen_tcp.send(relay, KeeperProtocol.frames(:control, last))
      :ok = :gen_tcp.close(relay)
      queued_at_least(c.client, 2)
      :ok = :sys.resume(c.client)

      assert {:error, _reason} = Task.await(writer)
      assert heard(handle) == [{:control, last}, :control_closed, :relay_closed]
    end

    @tag timeout: 60_000
    test "a runner's control frame received while a write waits out its bound reaches its owner first" do
      c = plain_client!()
      {handle, relay} = attached_runner!(c)
      chunk = :binary.copy("x", KeeperProtocol.max_frame_bytes())

      writer =
        Task.async(fn ->
          Stream.repeatedly(fn -> Keeper.send_control(handle, chunk) end)
          |> Enum.find(&(&1 != :ok))
        end)

      # Once a write waits on the full connection, the runner writes its
      # last line, which the client receives while it waits.
      wait_until(fn -> writing?(writer!(c, handle)) end, 5_000)
      last = ~s({"type":"complete"}\n)
      :ok = :gen_tcp.send(relay, KeeperProtocol.frames(:control, last))

      assert {:error, :timeout} = Task.await(writer, 15_000)
      assert heard(handle) == [{:control, last}, :control_closed, :relay_closed]
      :gen_tcp.close(relay)
    end

    # The keeper reports a spawn released once its relay has ended, so what
    # the relay wrote before it is all on the connection: it reaches the
    # owner, in the wire's order and without its word, before the release.
    test "a runner's last frames reach its owner before its release, though it took nothing" do
      c = plain_client!()
      {%{ref: ref}, relay} = attached_runner!(c)
      :ok = :gen_tcp.send(relay, KeeperProtocol.frames(:control, "first"))
      assert_receive {Keeper, ^ref, {:control, "first"}}, 5_000

      # The owner does not take the first: the last waits on the socket
      # when the relay ends and the keeper reports the end.
      :ok = :gen_tcp.send(relay, KeeperProtocol.frames(:control, "last"))
      :ok = :gen_tcp.close(relay)
      id = String.duplicate("cd", 16)
      exit = %{v: 5, type: "exited", spawn_id: id, code: 0, signal: nil, memory: nil}
      released = %{v: 5, type: "released", spawn_id: id}
      :ok = :socket.send(c.peer, [Jason.encode!(exit), ?\n, Jason.encode!(released), ?\n])

      assert until_released(ref) ==
               [
                 {:control, "last"},
                 :control_closed,
                 :relay_closed,
                 {:exited, {:status, 0}, nil},
                 :released
               ]
    end
  end

  describe "a held connection" do
    # A program spawned for the test and attached on a client whose
    # channel's far end the test holds, the test its relay: its handle and
    # the relay's end. A task answers the spawn on the channel, since the
    # spawn is answered only once cyfr-locus reports it spawned.
    defp attached_program!(c) do
      id = "pl-" <> Integer.to_string(System.unique_integer([:positive]))
      placed!(c, id)
      peer = c.peer

      answering =
        Task.async(fn ->
          %{"id" => request_id, "attach" => %{"token" => token}} = request(peer)
          spawn_id = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
          spawned = %{v: 5, type: "spawned", id: request_id, spawn_id: spawn_id, uid: 1, pid: 1}
          :ok = :socket.send(peer, [Jason.encode!(spawned), ?\n])
          token
        end)

      assert {:ok, %{ref: ref} = handle} =
               Keeper.spawn(c.name, %{
                 argv: ["/bin/cat"],
                 env: %{},
                 place: id,
                 pool: "backends",
                 memory_bytes: 268_435_456,
                 cpu_quota: 100_000
               })

      token = Task.await(answering)

      {:ok, relay} =
        :gen_tcp.connect({:local, Path.join(c.attach_dir, "attach.sock")}, 0, [
          :binary,
          active: false
        ])

      :ok = :gen_tcp.send(relay, KeeperProtocol.attach_frame(token))
      assert_receive {Keeper, ^ref, :attached}, 5_000
      {handle, relay}
    end

    # The process writing to `handle`'s connection: its writer, or none
    # where the client writes itself.
    defp writer_of(c, %{ref: ref}), do: Map.get(:sys.get_state(c.client).requests[ref], :writer)

    defp held_writing?(nil), do: false
    defp held_writing?(pid), do: writing?(pid)

    # The stdout bytes `handle`'s owner is told, taking each piece, until
    # `bytes` have come.
    defp take_stdout(%{ref: ref} = handle, bytes, acc \\ []) do
      if IO.iodata_length(acc) >= bytes do
        IO.iodata_to_binary(acc)
      else
        assert_receive {Keeper, ^ref, {:stdout, piece}}, 5_000
        :ok = Keeper.taken(handle)
        take_stdout(handle, bytes, [acc, piece])
      end
    end

    # The stdout pieces already told to the owner, read from its mailbox
    # without its word: their bytes and how many.
    defp told(ref, {bytes, count} \\ {0, 0}) do
      receive do
        {Keeper, ^ref, {:stdout, piece}} -> told(ref, {bytes + byte_size(piece), count + 1})
      after
        0 -> {bytes, count}
      end
    end

    @tag timeout: 60_000
    test "is read one read at a time: what its relay writes past the read waits until the owner took every frame of it" do
      c = plain_client!()
      {%{ref: ref} = handle, relay} = attached_program!(c)
      payload = :binary.copy("x", KeeperProtocol.max_frame_bytes())
      frames = 64
      frame = KeeperProtocol.frames(:stdout, payload)
      sending = Task.async(fn -> for _ <- 1..frames, do: :ok = :gen_tcp.send(relay, frame) end)

      # The owner takes nothing: it is told at most one read, and the relay
      # waits behind the socket.
      assert_receive {Keeper, ^ref, {:stdout, first}}, 5_000
      assert Task.yield(sending, 1_000) == nil
      {more, pieces} = told(ref)
      held = byte_size(first) + more
      assert held <= KeeperProtocol.max_frame_bytes() + 5

      # Taking each frame it is told, the owner is told every byte, in order,
      # and the relay ends its writes.
      for _ <- 0..pieces, do: :ok = Keeper.taken(handle)
      rest = take_stdout(handle, frames * byte_size(payload) - held)
      assert rest == :binary.copy("x", frames * byte_size(payload) - held)
      Task.await(sending)
      :gen_tcp.close(relay)
    end

    @tag timeout: 60_000
    test "a relay that stops reading its input holds its writer and the callers waiting on it, never the client or another spawn" do
      c = plain_client!()
      {stuck, _stuck_relay} = attached_program!(c)
      {%{ref: other_ref} = other, other_relay} = attached_program!(c)

      # The stuck program's relay reads nothing: its writes wait on its
      # full connection, the second behind the first.
      big = :binary.copy("x", 4 * 1_048_576)

      waiting =
        Task.async(fn ->
          first = Keeper.send(stuck, big)
          _second = Keeper.send(stuck, big)
          first
        end)

      wait_until(fn -> writing?(c.client) or held_writing?(writer_of(c, stuck)) end, 5_000)

      # Meanwhile the client answers, writes to another spawn and tells its
      # owner what it wrote.
      assert %{requests: %{}} = :sys.get_state(c.client, 1_000)
      assert :ok = Keeper.send(other, "hello")
      expected = IO.iodata_to_binary(KeeperProtocol.frames(:stdin, "hello"))
      assert {:ok, ^expected} = :gen_tcp.recv(other_relay, byte_size(expected), 1_000)
      :ok = :gen_tcp.send(other_relay, KeeperProtocol.frames(:stdout, "out"))
      assert_receive {Keeper, ^other_ref, {:stdout, "out"}}, 1_000
      assert Task.yield(waiting, 0) == nil

      # The stuck write waits out its bound alone, refused.
      assert {:error, :stdin_closed} = Task.await(waiting, 15_000)
      :gen_tcp.close(other_relay)
    end

    @tag timeout: 60_000
    test "a write is answered once written, what waits to be written is its callers', and the writer ends with its connection" do
      c = plain_client!()
      {handle, relay} = attached_program!(c)
      writer = writer_of(c, handle)
      big = :binary.copy("x", 1_048_576)

      # The relay reads nothing yet: the first write waits on the connection
      # and the second behind it, each with its caller, unanswered.
      first = Task.async(fn -> Keeper.send(handle, big) end)
      wait_until(fn -> held_writing?(writer) end, 5_000)
      second = Task.async(fn -> Keeper.send(handle, "after") end)

      wait_until(
        fn -> Process.info(writer, :message_queue_len) == {:message_queue_len, 1} end,
        5_000
      )

      assert Task.yield(first, 200) == nil
      assert Task.yield(second, 0) == nil
      assert Process.info(c.client, :message_queue_len) == {:message_queue_len, 0}

      # The relay reads: each is answered, in order, once its bytes are
      # written.
      expected =
        IO.iodata_to_binary([
          KeeperProtocol.frames(:stdin, big),
          KeeperProtocol.frames(:stdin, "after")
        ])

      assert {:ok, ^expected} = :gen_tcp.recv(relay, byte_size(expected), 5_000)
      assert Task.await(first) == :ok
      assert Task.await(second) == :ok

      # Two writes wait again; the relay goes: both are answered at once,
      # within the write bound, and the writer ends with its connection.
      first = Task.async(fn -> Keeper.send(handle, :binary.copy(big, 4)) end)
      wait_until(fn -> held_writing?(writer) end, 5_000)
      second = Task.async(fn -> Keeper.send(handle, "after") end)

      wait_until(
        fn -> Process.info(writer, :message_queue_len) == {:message_queue_len, 1} end,
        5_000
      )

      started = System.monotonic_time(:millisecond)
      :ok = :gen_tcp.close(relay)
      assert {:error, :stdin_closed} = Task.await(first, 5_000)
      assert {:error, :stdin_closed} = Task.await(second, 5_000)
      assert System.monotonic_time(:millisecond) - started < 4_000
      wait_until(fn -> not Process.alive?(writer) end, 5_000)

      # A write to the connection that is gone is answered at once.
      assert {:error, _gone} = Keeper.send(handle, "late")
    end

    # Every event of `ref`, in order, until and with the first that `last?`
    # holds for (its `:released`).
    defp until_released(ref, last? \\ &(&1 == :released), acc \\ []) do
      receive do
        {Keeper, ^ref, event} ->
          if last?.(event),
            do: Enum.reverse([event | acc]),
            else: until_released(ref, last?, [event | acc])
      after
        5_000 -> flunk("no last event after #{inspect(Enum.reverse(acc))}")
      end
    end

    defp channel_reply(c, reply), do: :ok = :socket.send(c.peer, [Jason.encode!(reply), ?\n])

    test "a spawn's frames after its leader's exit reach its owner before the exit" do
      c = plain_client!()
      {%{ref: ref, spawn_id: id} = handle, relay} = attached_program!(c)
      :ok = :gen_tcp.send(relay, KeeperProtocol.frames(:stdout, "one"))
      assert_receive {Keeper, ^ref, {:stdout, "one"}}, 5_000

      # The leader exits while the owner holds its first frame untaken and
      # the relay still carries the last: that waits for the owner's word as
      # any read does, and the exit waits behind it.
      channel_reply(c, %{v: 5, type: "exited", spawn_id: id, code: 0, signal: nil, memory: nil})
      :ok = :gen_tcp.send(relay, KeeperProtocol.frames(:stdout, "two"))
      :ok = :gen_tcp.close(relay)
      refute_receive {Keeper, ^ref, _event}, 500

      :ok = Keeper.taken(handle)
      assert_receive {Keeper, ^ref, {:stdout, "two"}}, 5_000
      :ok = Keeper.taken(handle)
      assert until_released(ref, &match?({:exited, _, _, _}, &1)) == [{:exited, 0, nil, nil}]

      channel_reply(c, %{v: 5, type: "released", spawn_id: id})
      assert until_released(ref) == [:released]
    end

    # The relay sends `frames` frames of the largest payload from a task of
    # its own: the task, the payload and their bytes together.
    defp flooding(relay, frames) do
      payload = :binary.copy("y", KeeperProtocol.max_frame_bytes())
      frame = KeeperProtocol.frames(:stdout, payload)
      sending = Task.async(fn -> Enum.map(1..frames, fn _ -> :gen_tcp.send(relay, frame) end) end)
      {sending, frames * byte_size(payload)}
    end

    # Takes each stdout piece `handle`'s owner is told until the relay's
    # task has sent every frame and its socket has handed the kernel every
    # byte, as a relay's writes have once it ends: the bytes it took. The
    # task's last send can return, and the keeper read and tell its bytes,
    # before the task's answer arrives, so the next event awaited is
    # whichever comes first, a piece or that answer, never a piece alone.
    defp take_while_sending(handle, sending, relay, bytes) do
      :ok = Keeper.taken(handle)
      next_piece(handle, sending, relay, bytes)
    end

    defp next_piece(%{ref: ref} = handle, sending, relay, bytes) do
      if sending == nil and :erlang.port_info(relay, :queue_size) == {:queue_size, 0} do
        bytes
      else
        task = sending && sending.ref

        receive do
          {Keeper, ^ref, {:stdout, piece}} ->
            take_while_sending(handle, sending, relay, bytes + byte_size(piece))

          {^task, sent} when task != nil ->
            Process.demonitor(task, [:flush])
            assert Enum.all?(sent, &(&1 == :ok))
            next_piece(handle, nil, relay, bytes)
        after
          5_000 -> flunk("neither a piece nor the relay's end came within 5 s")
        end
      end
    end

    @tag timeout: 60_000
    test "from the release on, the connection is read on the owner's word until the relay ends, and what it left at once" do
      c = plain_client!()
      {%{ref: ref, spawn_id: id} = handle, relay} = attached_program!(c)
      {sending, total} = flooding(relay, 16)
      assert_receive {Keeper, ^ref, {:stdout, first}}, 5_000
      assert Task.yield(sending, 500) == nil

      # The release is asked while the relay still writes: the owner, which
      # took nothing, is told nothing more, and the relay waits behind it.
      :ok = Keeper.release(c.name, handle, 0)
      assert %{"type" => "release", "spawn_id" => ^id} = request(c.peer)
      refute_receive {Keeper, ^ref, {:stdout, _piece}}, 1_000
      assert Task.yield(sending, 0) == nil

      # Taking each piece it is told, the owner lets the relay write the
      # rest; the relay ends and the keeper reports its end.
      taken = take_while_sending(handle, sending, relay, byte_size(first))
      :ok = :gen_tcp.close(relay)

      channel_reply(c, %{
        v: 5,
        type: "exited",
        spawn_id: id,
        code: nil,
        signal: "SIGKILL",
        memory: nil
      })

      channel_reply(c, %{v: 5, type: "released", spawn_id: id})

      # What the relay left is handed over at once, without the owner's
      # word: at most the table's figure for it, the relay's socket queue
      # and one read.
      told = until_released(ref)
      left = IO.iodata_length(for {:stdout, piece} <- told, do: piece)
      memory = Prima.LocusRoles.release().memory
      assert taken + left == total
      assert left <= memory.relay_queue_bytes + memory.keeper_read_bytes
      assert Enum.take(told, -2) == [{:exited, nil, "SIGKILL", nil}, :released]
    end

    @tag timeout: 60_000
    test "an owner that takes nothing for the drain's bound once its spawn's end began loses what its connection had not read, the connection closed" do
      c = plain_client!()
      {%{ref: ref, spawn_id: id} = handle, relay} = attached_program!(c)
      owing_from = System.monotonic_time(:millisecond)
      {sending, _total} = flooding(relay, 16)
      assert_receive {Keeper, ^ref, {:stdout, _first}}, 5_000

      # The release is asked and the owner takes nothing: its connection is
      # closed once it has owed its word for the bound, which fails the
      # relay's writes, and the log says so.
      log =
        capture_log(fn ->
          :ok = Keeper.release(c.name, handle, 0)
          assert %{"type" => "release", "spawn_id" => ^id} = request(c.peer)
          sent = Task.await(sending, 15_000)
          closed_after = System.monotonic_time(:millisecond) - owing_from
          assert Enum.any?(sent, &match?({:error, _closed}, &1))
          assert closed_after >= 5_000
        end)

      assert log =~ "took nothing of what it was told for 5000 ms after its end began"

      # The owner was told the one read it owes for and nothing past it;
      # the spawn's end follows at the keeper's word.
      assert told(ref) == {0, 0}

      channel_reply(c, %{
        v: 5,
        type: "exited",
        spawn_id: id,
        code: nil,
        signal: "SIGKILL",
        memory: nil
      })

      channel_reply(c, %{v: 5, type: "released", spawn_id: id})
      assert until_released(ref) == [{:exited, nil, "SIGKILL", nil}, :released]
    end

    test "a write whose caller is gone before its writer begins it is not written" do
      c = plain_client!()
      {handle, relay} = attached_program!(c)
      writer = writer_of(c, handle)
      :erlang.suspend_process(writer)
      caller = spawn(fn -> Keeper.send(handle, "hello") end)

      wait_until(
        fn -> Process.info(writer, :message_queue_len) == {:message_queue_len, 1} end,
        5_000
      )

      monitor = Process.monitor(caller)
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^monitor, _, _, _}, 5_000
      :erlang.resume_process(writer)
      assert {:error, :timeout} = :gen_tcp.recv(relay, 0, 500)
    end

    test "a write past the four that wait for a connection is refused at once" do
      c = plain_client!()
      {handle, relay} = attached_program!(c)
      writer = writer_of(c, handle)
      :erlang.suspend_process(writer)

      # Each write reaches the writer before the next is made, so they wait
      # in the order made.
      waiting =
        for n <- 1..4 do
          task = Task.async(fn -> Keeper.send(handle, "w#{n}") end)

          wait_until(
            fn -> Process.info(writer, :message_queue_len) == {:message_queue_len, n} end,
            5_000
          )

          task
        end

      assert {:error, :stdin_closed} = Keeper.send(handle, "past")
      :erlang.resume_process(writer)
      assert Enum.map(waiting, &Task.await/1) == [:ok, :ok, :ok, :ok]

      expected = IO.iodata_to_binary(for n <- 1..4, do: KeeperProtocol.frames(:stdin, "w#{n}"))
      assert {:ok, ^expected} = :gen_tcp.recv(relay, byte_size(expected), 5_000)
      assert {:error, :timeout} = :gen_tcp.recv(relay, 0, 200)
    end

    # The smallest legal frames, as many as one read holds: the owner is
    # told them as one message, so what it holds is the read's bytes and
    # not a message for each frame.
    test "one read of the smallest frames reaches its owner as one message a stream, within the table's figure for a read" do
      c = plain_client!()
      {%{ref: ref}, relay} = attached_program!(c)
      memory = Prima.LocusRoles.release().memory
      row = memory.keeper_read_bytes * memory.keeper_read_copies
      out = IO.iodata_to_binary(KeeperProtocol.frames(:stdout, "x"))
      err = IO.iodata_to_binary(KeeperProtocol.frames(:stderr, "e"))
      read = :binary.copy(out <> err, div(60_000, byte_size(out) * 2))
      :erlang.garbage_collect()
      {:memory, before} = Process.info(self(), :memory)
      :ok = :gen_tcp.send(relay, read)

      wait_until(fn -> Process.info(self(), :message_queue_len) |> elem(1) >= 2 end, 5_000)
      :erlang.garbage_collect()
      {:memory, held} = Process.info(self(), :memory)
      assert held - before <= row, "the owner holds #{held - before} bytes, the row #{row}"

      {:messages, messages} = Process.info(self(), :messages)
      told = for {Keeper, ^ref, event} <- messages, do: event
      stdout = for {:stdout, piece} <- told, do: piece
      stderr = for {:stderr, piece} <- told, do: piece
      assert IO.iodata_to_binary(stdout) == :binary.copy("x", div(byte_size(read), 12))
      assert IO.iodata_to_binary(stderr) == :binary.copy("e", div(byte_size(read), 12))
      assert length(told) <= 2 * 2
    end

    test "a writer ends with its client's normal stop" do
      c = plain_client!()
      {handle, relay} = attached_program!(c)
      writer = writer_of(c, handle)
      monitor = Process.monitor(writer)
      GenServer.stop(c.client, :normal)
      assert_receive {:DOWN, ^monitor, :process, ^writer, _reason}, 5_000
      :gen_tcp.close(relay)
    end

    test "a caller waiting on a writer that dies is answered at once" do
      c = plain_client!()
      {handle, relay} = attached_program!(c)
      writer = writer_of(c, handle)
      :erlang.suspend_process(writer)
      waiting = Task.async(fn -> Keeper.send(handle, "hello") end)

      wait_until(
        fn -> Process.info(writer, :message_queue_len) == {:message_queue_len, 1} end,
        5_000
      )

      Process.exit(writer, :kill)
      assert {:ok, {:error, _closed}} = Task.yield(waiting, 1_000)
      :gen_tcp.close(relay)
    end

    test "a write before the relay attaches is answered once the attached connection wrote it, or refused at the spawn's end" do
      c = plain_client!()

      for attaches? <- [true, false] do
        id = "pre-" <> Integer.to_string(System.unique_integer([:positive]))
        placed!(c, id)
        peer = c.peer

        answering =
          Task.async(fn ->
            %{"id" => request_id, "attach" => %{"token" => token}} = request(peer)
            spawn_id = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

            :ok =
              :socket.send(peer, [
                Jason.encode!(%{
                  v: 5,
                  type: "spawned",
                  id: request_id,
                  spawn_id: spawn_id,
                  uid: 1,
                  pid: 1
                }),
                ?\n
              ])

            {token, spawn_id}
          end)

        {:ok, %{ref: ref} = handle} =
          Keeper.spawn(c.name, %{
            argv: ["/bin/cat"],
            env: %{},
            place: id,
            pool: "backends",
            memory_bytes: 268_435_456,
            cpu_quota: 100_000
          })

        {token, spawn_id} = Task.await(answering)
        writing = Task.async(fn -> Keeper.send(handle, "hello") end)
        assert Task.yield(writing, 300) == nil

        if attaches? do
          {:ok, relay} =
            :gen_tcp.connect({:local, Path.join(c.attach_dir, "attach.sock")}, 0, [
              :binary,
              active: false
            ])

          :ok = :gen_tcp.send(relay, KeeperProtocol.attach_frame(token))
          assert_receive {Keeper, ^ref, :attached}, 5_000
          expected = IO.iodata_to_binary(KeeperProtocol.frames(:stdin, "hello"))
          assert {:ok, ^expected} = :gen_tcp.recv(relay, byte_size(expected), 5_000)
          assert Task.await(writing) == :ok
          :gen_tcp.close(relay)
        else
          channel_reply(c, %{v: 5, type: "released", spawn_id: spawn_id})
          assert {:error, :stdin_closed} = Task.await(writing)
        end
      end
    end

    test "a writer ends with the client" do
      c = plain_client!()
      {handle, relay} = attached_program!(c)
      writer = writer_of(c, handle)
      monitor = Process.monitor(writer)
      Process.exit(c.client, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^writer, _reason}, 5_000
      :gen_tcp.close(relay)
    end
  end

  describe "a long-lived spawn against the fake keeper" do
    setup do
      {:ok, FakeKeeper.start_client!()}
    end

    # A spawn of `script` in `place`, or in a place made for it.
    defp spawn_live(name, script, env \\ %{}, place \\ nil) do
      Keeper.spawn(name, %{
        argv: ["/bin/sh", "-c", script],
        env: env,
        place: place || place!(name),
        pool: "backends",
        memory_bytes: 268_435_456,
        cpu_quota: 100_000
      })
    end

    # The events of `handle` until its release, the last, in order, with
    # stdout and stderr each joined where they arrived in pieces.
    defp events_until_released(%{ref: ref} = handle, acc \\ []) do
      receive do
        {Keeper, ^ref, :released} ->
          joined(Enum.reverse([:released | acc]))

        {Keeper, ^ref, event} ->
          took(handle, event)
          events_until_released(handle, [event | acc])
      after
        10_000 -> flunk("no release; heard #{length(acc)} events")
      end
    end

    # The exit and the release that end `events`, the release last: the
    # exit comes on the channel and the streams on the relay's connection,
    # so a stream's last frame may follow the exit, and only the release
    # waits for the relay to deliver everything (Locus.Keeper).
    defp ending(events) do
      assert List.last(events) == :released
      assert [exited] = Enum.filter(events, &match?({:exited, _, _, _}, &1))
      [exited, :released]
    end

    # The streams of `events`, each joined across the exit, which may fall
    # between two of a stream's frames.
    defp streams(events),
      do:
        events
        |> Enum.filter(&match?({stream, _} when stream in [:stdout, :stderr], &1))
        |> joined()

    defp joined(events) do
      events
      |> Enum.chunk_by(&(is_tuple(&1) and elem(&1, 0) in [:stdout, :stderr] and elem(&1, 0)))
      |> Enum.flat_map(fn
        [{stream, _} | _] = chunk when stream in [:stdout, :stderr] ->
          [{stream, chunk |> Enum.map(&elem(&1, 1)) |> IO.iodata_to_binary()}]

        chunk ->
          chunk
      end)
    end

    defp requests(fake, type),
      do: fake |> FakeKeeper.requests() |> Enum.filter(&(&1["type"] == type))

    # The requests of `type` the fake has recorded, once one has reached it.
    defp recorded(fake, type) do
      wait_until(fn -> requests(fake, type) != [] end, 5_000)
      requests(fake, type)
    end

    test "a spawn answers its handle and its owner hears it attached, its streams apart, its exit and its release",
         %{name: name, fake: fake} do
      assert {:ok, handle} =
               spawn_live(name, ~s(echo out; echo "$GREETING" >&2; exit 4), %{
                 "GREETING" => "hello"
               })

      assert handle.spawn_id =~ ~r/^[0-9a-f]{32}$/
      assert handle.uid == 30_001 and is_integer(handle.pid)

      events = events_until_released(handle)
      assert hd(events) == :attached
      assert {:stdout, "out\n"} in streams(events)
      assert {:stderr, "hello\n"} in streams(events)
      assert ending(events) == [{:exited, 4, nil, nil}, :released]

      [spawn] = recorded(fake, "spawn")
      assert spawn["pool"] == "backends"
      assert spawn["memory_bytes"] == 268_435_456
      assert spawn["env"] == %{"GREETING" => "hello"}

      # Nothing is heard of a spawn after its release.
      refute_receive {Keeper, _ref, _event}, 200
    end

    test "a spec without a memory bound or a CPU quota is refused before cyfr-locus is asked anything",
         %{name: name, fake: fake} do
      for spec <- [
            %{argv: ["true"], env: %{}, pool: "backends", cpu_quota: 100_000},
            %{argv: ["true"], env: %{}, pool: "backends", memory_bytes: nil, cpu_quota: 100_000},
            %{argv: ["true"], env: %{}, pool: "backends", memory_bytes: 0, cpu_quota: 100_000},
            %{argv: ["true"], env: %{}, pool: "backends", memory_bytes: 268_435_456},
            %{argv: ["true"], env: %{}, pool: "backends", memory_bytes: 268_435_456, cpu_quota: 0}
          ] do
        spec = Map.put(spec, :place, "pl-1")
        assert_raise FunctionClauseError, fn -> Keeper.spawn(name, spec) end
      end

      assert requests(fake, "spawn") == []
    end

    test "stdin is written as frames of the codec's bound, held until the relay attaches", %{
      name: name
    } do
      assert {:ok, handle} = spawn_live(name, "exec head -c 150000")
      data = :binary.copy("0123456789", 15_000)
      assert length(KeeperProtocol.frames(:stdin, data)) == 3
      assert :ok = Keeper.send(handle, data)

      events = events_until_released(handle)
      assert {:stdout, ^data} = Enum.find(events, &match?({:stdout, _}, &1))
      assert {:exited, 0, nil, nil} in events
    end

    test "signal signals the spawn and is the vectors' request", %{name: name, fake: fake} do
      assert {:ok, handle} = spawn_live(name, "echo ready; exec sleep 30")
      assert_receive {Keeper, _ref, {:stdout, "ready\n"}}, 10_000
      :ok = Keeper.taken(handle)

      assert {:error, :unencodable} = Keeper.signal(handle, "SIGSTOP")
      assert :ok = Keeper.signal(handle, "SIGTERM")

      assert ending(events_until_released(handle)) == [{:exited, nil, "SIGTERM", nil}, :released]

      [signal] = recorded(fake, "signal")
      vector = Enum.find(@vectors["valid_requests"], &(&1["type"] == "signal"))
      assert signal == %{vector | "spawn_id" => handle.spawn_id}

      assert {:error, :unknown_spawn} = Keeper.signal(handle, "SIGTERM")
    end

    test "resize is the vectors' request naming the spawn, and a released or unknown spawn's is unknown_spawn",
         %{name: name, fake: fake} do
      assert {:ok, handle} = spawn_live(name, "echo ready; exec sleep 30")
      assert_receive {Keeper, _ref, {:stdout, "ready\n"}}, 10_000
      :ok = Keeper.taken(handle)

      assert :ok = Keeper.resize(handle, 50, 132)

      [resize] = recorded(fake, "resize")
      vector = Enum.find(@vectors["valid_requests"], &(&1["type"] == "resize"))
      assert resize == %{vector | "spawn_id" => handle.spawn_id}

      :ok = Keeper.release(name, handle, 0)
      assert ending(events_until_released(handle)) == [{:exited, nil, "SIGKILL", nil}, :released]

      assert {:error, :unknown_spawn} = Keeper.resize(handle, 24, 80)
      assert {:error, :unknown_spawn} = Keeper.resize(%{handle | ref: make_ref()}, 24, 80)
      assert [^resize] = requests(fake, "resize")
    end

    test "release with a grace lets the spawn end on its own, and is the vectors' request", %{
      name: name,
      fake: fake
    } do
      script = ~s(trap 'echo term; exit 0' TERM; echo ready; while :; do sleep 0.1; done)
      assert {:ok, handle} = spawn_live(name, script)
      assert_receive {Keeper, _ref, {:stdout, "ready\n"}}, 10_000
      :ok = Keeper.taken(handle)

      assert :ok = Keeper.release(name, handle, 2_000)
      events = events_until_released(handle)
      assert {:stdout, "term\n"} in streams(events)
      assert ending(events) == [{:exited, 0, nil, nil}, :released]

      [release] = recorded(fake, "release")
      vector = Enum.find(@vectors["valid_requests"], &(&1["type"] == "release"))
      assert release == %{vector | "spawn_id" => handle.spawn_id}
    end

    # A shell runs its trap once more for a term that arrives while the trap
    # runs, so a spawn whose trap outlasts the release's signal prints its
    # line once for each term it is sent.
    test "release with a grace sends the spawn's group one term signal", %{name: name} do
      script = ~s(trap 'echo term; sleep 0.5' TERM; echo ready; while :; do sleep 0.1; done)
      assert {:ok, handle} = spawn_live(name, script)
      assert_receive {Keeper, _ref, {:stdout, "ready\n"}}, 10_000
      :ok = Keeper.taken(handle)

      assert :ok = Keeper.release(name, handle, 1_500)
      events = events_until_released(handle)
      assert {:stdout, "term\n"} in streams(events)
      assert ending(events) == [{:exited, nil, "SIGKILL", nil}, :released]
    end

    test "release with no grace kills the spawn", %{name: name, fake: fake} do
      assert {:ok, handle} = spawn_live(name, "echo ready; exec sleep 30")
      assert_receive {Keeper, _ref, {:stdout, "ready\n"}}, 10_000
      :ok = Keeper.taken(handle)

      :ok = Keeper.release(name, handle, 0)

      assert ending(events_until_released(handle)) == [{:exited, nil, "SIGKILL", nil}, :released]

      assert [%{"grace_ms" => 0}] = recorded(fake, "release")
    end

    test "a kill at the spawn's cap, one for the container's limit and one for neither reach its owner apart",
         %{name: name, fake: fake} do
      for {spelled, memory} <- [
            {"cap", :cap},
            {"machine", :machine},
            {"either", :either},
            {nil, nil}
          ] do
        :ok = FakeKeeper.mode(fake, {:exit, %{code: nil, signal: "SIGKILL", memory: spelled}})
        assert {:ok, handle} = spawn_live(name, "unused")

        assert ending(events_until_released(handle)) ==
                 [{:exited, nil, "SIGKILL", memory}, :released]
      end
    end

    test "a measure of a place is the vectors' request, answered with the keeper's reading, whose the place is and its age",
         %{name: name, fake: fake} do
      vector = Enum.find(@vectors["valid_requests"], &(&1["type"] == "measure"))
      place = vector["place"]
      whose = %{kind: "program", athanor: "ath_measured", subject: "mcp_measured"}
      assert :ok = Keeper.place(name, place, whose, self())
      assert {:ok, _handle} = spawn_live(name, "exec cat", %{}, place)

      # A place the keeper has not read yet has no reading, never a zero.
      assert {:error, {:refused, "unmeasured"}} = Keeper.measure(name, place)

      :ok = FakeKeeper.mode(fake, {:measured, %{bytes: 268_435_456, lesser: true, age_ms: 1_250}})

      assert Keeper.measure(name, place) ==
               {:ok,
                %{
                  kind: "program",
                  athanor: "ath_measured",
                  subject: "mcp_measured",
                  bytes: 268_435_456,
                  lesser: true,
                  age_ms: 1_250
                }}

      assert [first, second] = requests(fake, "measure")
      assert first["id"] != second["id"]

      assert [%{first | "id" => vector["id"]}, %{second | "id" => vector["id"]}] == [
               vector,
               vector
             ]
    end

    test "a place the keeper does not hold, one dropped and one whose spawn was released are unmeasured",
         %{name: name, fake: fake} do
      :ok = FakeKeeper.mode(fake, {:measured, %{bytes: 1_048_576, lesser: false, age_ms: 0}})
      assert {:error, {:refused, "unmeasured"}} = Keeper.measure(name, "pl-never")

      dropped = place!(name)
      :ok = Keeper.drop(name, dropped)
      assert {:error, {:refused, "unmeasured"}} = Keeper.measure(name, dropped)
      refute Map.has_key?(FakeKeeper.places(fake), dropped)

      released = place!(name)
      assert {:ok, handle} = spawn_live(name, "exec cat", %{}, released)
      assert {:ok, %{kind: "program", bytes: 1_048_576}} = Keeper.measure(name, released)
      :ok = Keeper.release(name, handle, 0)
      assert List.last(events_until_released(handle)) == :released
      assert {:error, {:refused, "unmeasured"}} = Keeper.measure(name, released)
      assert FakeKeeper.places(fake) == %{}
    end

    test "pool_stats reads a pool with the vectors' request, and a refusal is the keeper's code",
         %{name: name, fake: fake} do
      assert {:ok, %{size: 4, free: 3, quarantined: 0}} = Keeper.pool_stats(name, "backends")

      [pool] = recorded(fake, "pool")
      vector = Enum.find(@vectors["valid_requests"], &(&1["type"] == "pool"))
      assert pool == %{vector | "id" => pool["id"]}

      :ok = FakeKeeper.mode(fake, :pool_refused)
      assert {:error, {:refused, "unknown_pool"}} = Keeper.pool_stats(name, "backends")
      assert {:error, :unencodable} = Keeper.pool_stats(name, "Not A Pool")
    end

    test "an owner that dies has its spawn released with no grace", %{name: name, fake: fake} do
      test = self()

      owner =
        spawn(fn ->
          {:ok, handle} = spawn_live(name, "exec sleep 30")
          send(test, {:spawned, handle})
          Process.sleep(:infinity)
        end)

      assert_receive {:spawned, handle}, 10_000
      Process.exit(owner, :kill)

      wait_until(fn -> Enum.any?(requests(fake, "release"), &(&1["grace_ms"] == 0)) end, 5_000)
      [release] = requests(fake, "release")
      assert release["spawn_id"] == handle.spawn_id
    end

    test "a spawn the keeper would refuse is refused before it is sent, and a keeper refusal is its code",
         %{name: name, fake: fake} do
      assert {:error, {:spawn_failed, :unencodable_command}} =
               spawn_live(name, "true", %{"PATH" => "/tmp"})

      assert requests(fake, "spawn") == []

      :ok = FakeKeeper.mode(fake, :capacity)
      assert {:error, {:refused, "capacity"}} = spawn_live(name, "true")
    end

    test "a spawn refused after the keeper made it is refused at once, and its heir and owner hear its release once, at the keeper's word",
         %{name: name, fake: fake} do
      tag = %{
        ledger: make_ref(),
        session: {make_ref(), "ss_refused"},
        athanor: "ath_refused",
        memory_bytes: 268_435_456,
        home_id: nil
      }

      :ok = FakeKeeper.mode(fake, {:exec_failed, self()})

      refused =
        Keeper.spawn(name, %{
          argv: ["/bin/sh", "-c", "exec cat"],
          env: %{},
          place: place!(name),
          pool: "backends",
          memory_bytes: 268_435_456,
          cpu_quota: 100_000,
          heir: {self(), tag}
        })

      assert_receive {:exec_failed, spawn_id}, 5_000

      # The refusal answers the spawn; what the keeper made of it is still
      # the keeper's, so nobody is told it is gone.
      fenced = Keeper.fence(name, tag)
      refute_received {Keeper, {:heir, ^tag}, :released}
      assert {:error, {:refused, "exec_failed", %{ref: ref, spawn_id: ^spawn_id}}} = refused
      refute_received {Keeper, ^ref, :released}
      assert fenced == :pending
      assert [%{"type" => "spawn"}] = requests(fake, "spawn")
      assert requests(fake, "release") == []

      :ok = FakeKeeper.released(fake, spawn_id)
      assert_receive {Keeper, {:heir, ^tag}, :released}, 5_000
      assert_receive {Keeper, ^ref, :released}, 5_000
      assert Keeper.fence(name, tag) == :none
      refute_received {Keeper, {:heir, ^tag}, :released}
      refute_received {Keeper, ^ref, :released}
      assert FakeKeeper.places(fake) == %{}
    end

    test "a spawn whose caller gave up on it before it was written is never written, and its heir hears none started",
         %{name: name, fake: fake, client: client} do
      tag = %{
        ledger: make_ref(),
        session: {make_ref(), "ss_gave_up"},
        athanor: "ath_gave_up",
        memory_bytes: 268_435_456,
        home_id: nil
      }

      heir = self()
      place = place!(name)

      # The client takes nothing while the caller waits: the spawn is still
      # queued when its caller stops waiting for it.
      :ok = :sys.suspend(client)

      asked =
        Task.async(fn ->
          Keeper.spawn(name, %{
            argv: ["/bin/sh", "-c", "exec sleep 30"],
            env: %{},
            place: place,
            pool: "backends",
            memory_bytes: 268_435_456,
            cpu_quota: 100_000,
            heir: {heir, tag}
          })
        end)

      assert {:error, {:launcher_unavailable, :timeout}} = Task.await(asked, 20_000)
      :ok = :sys.resume(client)

      assert_receive {Keeper, {:heir, ^tag}, :released}, 5_000
      assert Keeper.fence(name, tag) == :none
      assert requests(fake, "spawn") == []
    end

    test "a keeper that is gone answers as unavailable" do
      assert {:error, {:launcher_unavailable, :noproc}} =
               Keeper.spawn(:no_such_keeper, %{
                 argv: ["true"],
                 env: %{},
                 place: "pl-1",
                 pool: "backends",
                 memory_bytes: 268_435_456,
                 cpu_quota: 100_000
               })

      assert {:error, {:launcher_unavailable, :noproc}} =
               Keeper.pool_stats(:no_such_keeper, "backends")
    end

    test "losing the channel tells a long-lived spawn's owner so, and neither it nor its heir that the spawn is released",
         %{name: name, fake: fake, client: client} do
      tag = %{
        ledger: make_ref(),
        session: {make_ref(), "ss_lost"},
        athanor: "ath_lost",
        memory_bytes: 268_435_456,
        home_id: nil
      }

      assert {:ok, %{ref: ref}} =
               Keeper.spawn(name, %{
                 argv: ["/bin/sh", "-c", "exec sleep 30"],
                 env: %{},
                 place: place!(name),
                 pool: "backends",
                 memory_bytes: 268_435_456,
                 cpu_quota: 100_000,
                 heir: {self(), tag}
               })

      assert_receive {Keeper, ^ref, :attached}, 10_000
      down = Process.monitor(client)

      :ok = FakeKeeper.close(fake)
      assert_receive {Keeper, ^ref, {:error, :channel_lost}}, 5_000
      assert_receive {:DOWN, ^down, :process, ^client, {:shutdown, :channel_lost}}, 5_000
      refute_received {Keeper, ^ref, :released}
      refute_received {Keeper, {:heir, ^tag}, :released}
    end
  end

  describe "places against the fake keeper" do
    setup do
      {:ok, FakeKeeper.start_client!()}
    end

    defp vectors(type), do: Enum.filter(@vectors["valid_requests"], &(&1["type"] == type))

    test "a place is the vectors' request with its kind, athanor and subject, answered once the keeper holds it",
         %{name: name, fake: fake} do
      for vector <- vectors("place") do
        whose =
          for {key, value} <- vector,
              key in ~w(kind athanor subject),
              into: %{},
              do: {String.to_existing_atom(key), value}

        assert :ok = Keeper.place(name, vector["id"], whose, self())
        assert %{whose: held, spawn: nil} = FakeKeeper.places(fake)[vector["id"]]
        assert held == Map.take(vector, ~w(kind athanor subject))
      end

      assert requests(fake, "place") == vectors("place")
    end

    test "a place of an id the client follows is refused unasked, and one the keeper holds is the keeper's refusal",
         %{name: name, fake: fake} do
      assert :ok = Keeper.place(name, "pl-1", %{kind: "warm"}, self())

      assert {:error, {:refused, "bad_request"}} =
               Keeper.place(name, "pl-1", %{kind: "run"}, self())

      assert length(requests(fake, "place")) == 1

      # A spawn named it: the client follows it no more, and the keeper,
      # which holds it until the spawn's release, refuses it.
      assert {:ok, %{spawn_id: spawn_id}} = spawn_live(name, "exec cat", %{}, "pl-1")

      assert {:error, {:refused, "bad_request"}} =
               Keeper.place(name, "pl-1", %{kind: "run"}, self())

      assert length(requests(fake, "place")) == 2

      assert FakeKeeper.places(fake) == %{
               "pl-1" => %{whose: %{"kind" => "warm"}, spawn: spawn_id}
             }
    end

    test "a place whose owner dies before a spawn names it is dropped", %{name: name, fake: fake} do
      [drop] = vectors("drop")
      owner = spawn(fn -> Process.sleep(:infinity) end)
      assert :ok = Keeper.place(name, drop["place"], %{kind: "build"}, owner)
      Process.exit(owner, :kill)

      wait_until(fn -> requests(fake, "drop") != [] end, 5_000, "the place to be dropped")
      assert requests(fake, "drop") == [drop]
      assert FakeKeeper.places(fake) == %{}

      # The client follows it no more: its id is free to place again.
      assert :ok = Keeper.place(name, drop["place"], %{kind: "build"}, self())
    end

    test "a place whose owner dies while it is being placed is dropped, and its caller hears so",
         %{name: name, fake: fake, client: client} do
      owner = spawn(fn -> Process.sleep(:infinity) end)

      # The keeper reads nothing until the owner is gone.
      :ok = :sys.suspend(fake)
      placing = Task.async(fn -> Keeper.place(name, "pl-1", %{kind: "warm"}, owner) end)

      wait_until(
        fn -> Map.has_key?(:sys.get_state(client).places, "pl-1") end,
        5_000,
        "the place to be asked for"
      )

      Process.exit(owner, :kill)
      assert Task.await(placing, 5_000) == {:error, :dropped}
      :ok = :sys.resume(fake)

      wait_until(fn -> requests(fake, "drop") != [] end, 5_000, "the drop to reach the keeper")

      assert [%{"type" => "place", "id" => "pl-1"}, %{"type" => "drop", "place" => "pl-1"}] =
               Enum.filter(FakeKeeper.requests(fake), &(&1["type"] in ~w(place drop)))

      assert FakeKeeper.places(fake) == %{}
    end

    test "a place whose caller is killed with its call behind its owner's drop is dropped, though its owner lives",
         %{name: name, fake: fake, client: client} do
      # The owner drops the place of a preparation it cancelled before the
      # preparation's own call is read, and the preparation is killed.
      :ok = :sys.suspend(client)
      :ok = Keeper.drop(name, "pl-1")
      owner = self()
      caller = spawn(fn -> Keeper.place(name, "pl-1", %{kind: "program"}, owner) end)

      wait_until(
        fn -> Process.info(client, :message_queue_len) == {:message_queue_len, 2} end,
        5_000,
        "the drop and the place to wait at the client"
      )

      Process.exit(caller, :kill)
      :ok = :sys.resume(client)
      wait_until(fn -> requests(fake, "drop") != [] end, 5_000, "the place to be dropped")

      assert %{
               requests: Enum.filter(FakeKeeper.requests(fake), &(&1["type"] in ~w(place drop))),
               places: FakeKeeper.places(fake),
               again: Keeper.place(name, "pl-1", %{kind: "program"}, self())
             } == %{
               requests: [
                 %{"v" => 5, "type" => "place", "id" => "pl-1", "kind" => "program"},
                 %{"v" => 5, "type" => "drop", "place" => "pl-1"}
               ],
               places: %{},
               again: :ok
             }
    end

    test "a place whose call timed out is dropped, though its owner lives", %{
      name: name,
      fake: fake
    } do
      # The keeper reads nothing until the call has given up.
      :ok = :sys.suspend(fake)

      assert {:error, {:launcher_unavailable, :timeout}} =
               Keeper.place(name, "pl-1", %{kind: "build"}, self())

      :ok = :sys.resume(fake)
      wait_until(fn -> requests(fake, "drop") != [] end, 5_000, "the drop to reach the keeper")

      assert %{
               requests: Enum.filter(FakeKeeper.requests(fake), &(&1["type"] in ~w(place drop))),
               places: FakeKeeper.places(fake),
               again: Keeper.place(name, "pl-1", %{kind: "build"}, self())
             } == %{
               requests: [
                 %{"v" => 5, "type" => "place", "id" => "pl-1", "kind" => "build"},
                 %{"v" => 5, "type" => "drop", "place" => "pl-1"}
               ],
               places: %{},
               again: :ok
             }
    end

    test "a place a spawn named is the spawn's: its owner's death drops nothing, and the spawn's release frees it",
         %{name: name, fake: fake} do
      owner = spawn(fn -> Process.sleep(:infinity) end)
      monitor = Process.monitor(owner)
      assert :ok = Keeper.place(name, "pl-1", %{kind: "program"}, owner)
      assert {:ok, %{spawn_id: spawn_id} = handle} = spawn_live(name, "exec cat", %{}, "pl-1")

      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}, 5_000

      # A request asked after the owner died reaches the keeper after any
      # the death sent.
      assert {:ok, _stats} = Keeper.pool_stats(name, "backends")
      assert requests(fake, "drop") == []
      assert %{"pl-1" => %{spawn: ^spawn_id}} = FakeKeeper.places(fake)

      :ok = Keeper.release(name, handle, 0)
      assert List.last(events_until_released(handle)) == :released
      assert FakeKeeper.places(fake) == %{}
    end

    test "drop frees a place no spawn named, and leaves one a spawn named",
         %{name: name, fake: fake} do
      [drop] = vectors("drop")
      assert :ok = Keeper.place(name, drop["place"], %{kind: "build"}, self())
      assert :ok = Keeper.place(name, "pl-1", %{kind: "program"}, self())
      assert {:ok, _handle} = spawn_live(name, "exec cat", %{}, "pl-1")

      :ok = Keeper.drop(name, drop["place"])
      :ok = Keeper.drop(name, "pl-1")

      # Asked after both drops, so answered after the keeper read them.
      assert {:ok, _stats} = Keeper.pool_stats(name, "backends")
      assert requests(fake, "drop") == [drop]
      assert Map.keys(FakeKeeper.places(fake)) == ["pl-1"]

      # The dropped id is free to place again.
      assert :ok = Keeper.place(name, drop["place"], %{kind: "build"}, self())
    end

    test "assign changes whose the place is, answered once the keeper applied it: a measure answers its new kind and athanor",
         %{name: name, fake: fake} do
      assign = Enum.find(vectors("assign"), &(&1["kind"] == "run"))
      place = assign["place"]
      assert :ok = Keeper.place(name, place, %{kind: "warm"}, self())
      assert {:ok, _handle} = spawn_live(name, "exec cat", %{}, place)
      :ok = FakeKeeper.mode(fake, {:measured, %{bytes: 1_048_576, lesser: false, age_ms: 7}})
      assert {:ok, %{kind: "warm", athanor: nil, subject: nil}} = Keeper.measure(name, place)

      assert :ok = Keeper.assign(name, place, %{kind: "run", athanor: assign["athanor"]}, soon())

      assert Keeper.measure(name, place) ==
               {:ok,
                %{
                  kind: "run",
                  athanor: assign["athanor"],
                  subject: nil,
                  bytes: 1_048_576,
                  lesser: false,
                  age_ms: 7
                }}

      # The vectors' request, under an id of the client's own.
      assert [%{"id" => "assign-" <> _} = sent] = requests(fake, "assign")
      assert Map.delete(sent, "id") == Map.delete(assign, "id")
    end

    test "an assign of a place the keeper does not hold is its refusal, and one the codec refuses is never sent",
         %{name: name, fake: fake} do
      assert %{
               unheld: Keeper.assign(name, "pl-9", %{kind: "run"}, soon()),
               unwritten:
                 Keeper.assign(name, "pl-9", %{kind: "run", athanor: "family of mine"}, soon())
             } == %{
               unheld: {:error, {:refused, "bad_request"}},
               unwritten: {:error, :unencodable}
             }

      assert [%{"place" => "pl-9", "kind" => "run"}] = requests(fake, "assign")
    end

    test "a refused spawn frees its place", %{name: name, fake: fake} do
      assert :ok = Keeper.place(name, "pl-1", %{kind: "program"}, self())
      :ok = FakeKeeper.mode(fake, :capacity)
      assert {:error, {:refused, "capacity"}} = spawn_live(name, "true", %{}, "pl-1")
      assert FakeKeeper.places(fake) == %{}

      # The client follows it no more: its id is free to place again.
      :ok = FakeKeeper.mode(fake, :normal)
      assert :ok = Keeper.place(name, "pl-1", %{kind: "program"}, self())
    end
  end

  describe "kept homes against the fake keeper" do
    setup do
      root = FakeKeeper.short_tmp_dir()
      on_exit(fn -> File.rm_rf!(root) end)
      %File.Stat{uid: uid} = File.stat!(root)
      [root: root, uid: uid]
    end

    # The fake keeps every home as the test's own user, whose uid is every
    # home's.
    defp kept_client(root), do: FakeKeeper.start_client!(kept_root: root)

    defp home_requests(fake),
      do: for(%{"type" => "home_" <> _} = request <- FakeKeeper.requests(fake), do: request)

    test "home_ensure names the home by its id alone and answers the uid cyfr-locus names",
         %{root: root, uid: uid} do
      %{name: name, fake: fake} = kept_client(root)

      assert {:ok, ^uid} = Keeper.home_ensure(name, "vlt_a")
      assert File.dir?(Path.join(root, "vlt_a"))
      assert {:ok, ^uid} = Keeper.home_ensure(name, "vlt_a")
      assert {:error, {:refused, "bad_request"}} = Keeper.home_ensure(name, "../x")

      assert [
               %{"v" => 5, "type" => "home_make", "id" => first, "home" => "vlt_a"},
               %{"v" => 5, "type" => "home_make", "id" => second, "home" => "vlt_a"}
             ] = home_requests(fake)

      assert first != second
      assert Enum.all?(home_requests(fake), &(map_size(&1) == 4))
    end

    test "a refused home request is cyfr-locus's code", %{root: root} do
      %{name: name, fake: fake} = kept_client(root)

      for code <- ~w(capacity unavailable internal) do
        :ok = FakeKeeper.mode(fake, {:home_refused, code})

        for call <- [
              &Keeper.home_ensure/2,
              &Keeper.home_measure/2,
              &Keeper.home_reset/2,
              &Keeper.home_retire/2
            ],
            do: assert({:error, {:refused, ^code}} = call.(name, "vlt_a"))

        assert {:error, {:refused, ^code}} = Keeper.home_list(name)
      end
    end

    test "home_measure, home_reset and home_retire ask cyfr-locus by the home's id",
         %{root: root, uid: uid} do
      %{name: name, fake: fake} = kept_client(root)

      assert :absent = Keeper.home_measure(name, "vlt_a")
      assert :ok = Keeper.home_reset(name, "vlt_a")
      assert :ok = Keeper.home_retire(name, "vlt_a")
      refute File.exists?(Path.join(root, "vlt_a"))

      assert {:ok, ^uid} = Keeper.home_ensure(name, "vlt_a")
      File.write!(Path.join([root, "vlt_a", "notes"]), "0123456789")
      assert {:ok, 10} = Keeper.home_measure(name, "vlt_a")

      assert :ok = Keeper.home_reset(name, "vlt_a")
      assert File.ls!(Path.join(root, "vlt_a")) == []
      assert {:ok, 0} = Keeper.home_measure(name, "vlt_a")

      assert :ok = Keeper.home_retire(name, "vlt_a")
      refute File.exists?(Path.join(root, "vlt_a"))

      assert home_requests(fake) |> Enum.map(&{&1["type"], &1["home"]}) == [
               {"home_measure", "vlt_a"},
               {"home_reset", "vlt_a"},
               {"home_retire", "vlt_a"},
               {"home_make", "vlt_a"},
               {"home_measure", "vlt_a"},
               {"home_reset", "vlt_a"},
               {"home_measure", "vlt_a"},
               {"home_retire", "vlt_a"}
             ]
    end

    test "home_list gathers every page of cyfr-locus's list, sorted", %{root: root} do
      %{name: name, fake: fake} = kept_client(root)
      assert {:ok, []} = Keeper.home_list(name)

      for id <- ~w(vlt_e vlt_b vlt_a vlt_d vlt_c), do: {:ok, _uid} = Keeper.home_ensure(name, id)
      File.write!(Path.join(root, "not-a-home.txt"), "x")

      assert {:ok, ~w(vlt_a vlt_b vlt_c vlt_d vlt_e)} = Keeper.home_list(name)

      assert for(%{"type" => "home_list"} = list <- FakeKeeper.requests(fake), do: list["after"]) ==
               [nil, nil, "vlt_b", "vlt_d"]
    end

    test "a spawn in a kept home names the home by its id, its bound and its terminal",
         %{root: root, uid: uid} do
      %{name: name, fake: fake} = kept_client(root)

      spec = %{
        argv: ["true"],
        env: %{},
        pool: "backends",
        memory_bytes: 268_435_456,
        cpu_quota: 100_000
      }

      assert {:error, {:refused, "home_absent"}} =
               Keeper.spawn(name, Map.merge(spec, %{home: "vlt_a", place: place!(name)}))

      assert {:error, {:refused, "bad_request"}} =
               Keeper.spawn(name, Map.merge(spec, %{home: "../a", place: place!(name)}))

      assert {:ok, ^uid} = Keeper.home_ensure(name, "vlt_a")

      assert {:ok, _handle} =
               Keeper.spawn(
                 name,
                 Map.merge(spec, %{
                   home: "vlt_a",
                   home_max_bytes: 1_048_576,
                   pty: %{rows: 40, cols: 120},
                   place: place!(name)
                 })
               )

      assert [absent, spawn] = for(%{"type" => "spawn"} = r <- FakeKeeper.requests(fake), do: r)
      assert Map.take(absent, ~w(home_mode home)) == %{"home_mode" => "kept", "home" => "vlt_a"}

      assert Map.take(spawn, ~w(home_mode home home_path home_uid home_max_bytes pty)) == %{
               "home_mode" => "kept",
               "home" => "vlt_a",
               "home_max_bytes" => 1_048_576,
               "pty" => %{"rows" => 40, "cols" => 120}
             }

      :ok = FakeKeeper.mode(fake, :home_over_cap)

      assert {:error, {:refused, "home_over_cap"}} =
               Keeper.spawn(name, Map.merge(spec, %{home: "vlt_a", place: place!(name)}))
    end

    test "a spawn's hosts go with it, and a spawn refused for them is the keeper's code" do
      %{name: name, fake: fake} = FakeKeeper.start_client!()

      spec = %{
        argv: ["true"],
        env: %{},
        pool: "backends",
        memory_bytes: 268_435_456,
        cpu_quota: 100_000
      }

      assert {:ok, _handle} =
               Keeper.spawn(
                 name,
                 Map.merge(spec, %{
                   hosts: ["api.example.com", "registry.npmjs.org"],
                   place: place!(name)
                 })
               )

      assert {:ok, _handle} = Keeper.spawn(name, Map.put(spec, :place, place!(name)))

      assert [listed, open] = for(%{"type" => "spawn"} = r <- FakeKeeper.requests(fake), do: r)
      assert listed["hosts"] == ["api.example.com", "registry.npmjs.org"]
      refute Map.has_key?(open, "hosts")

      for code <- ~w(hosts_unresolved guard_unavailable) do
        :ok = FakeKeeper.mode(fake, String.to_existing_atom(code))

        assert {:error, {:refused, ^code}} =
                 Keeper.spawn(
                   name,
                   Map.merge(spec, %{hosts: ["api.example.com"], place: place!(name)})
                 )
      end
    end

    for op <- [:home_retire, :home_reset] do
      @tag op: op
      test "#{op} is never ok beside a make held past its caller's timeout, and is once it landed",
           %{root: root, op: op} do
        %{name: name, fake: fake} = kept_client(root)
        FakeKeeper.mode(fake, {:home_make_held, self()})
        assert {:timeout, _call} = catch_exit(GenServer.call(name, {:home_ensure, "vlt_a"}, 200))
        assert_receive {:home_make_held, make}, 2_000

        beside = apply(Keeper, op, [name, "vlt_a"])
        another_home = apply(Keeper, op, [name, "vlt_b"])
        :ok = FakeKeeper.release_make(fake, make)
        Prima.Test.Wait.wait_until(fn -> :sys.get_state(name).homes == %{} end, 5_000)
        landed = File.exists?(Path.join(root, "vlt_a"))
        again = apply(Keeper, op, [name, "vlt_a"])

        assert %{
                 beside: beside,
                 another_home: another_home,
                 landed: landed,
                 again: again,
                 folder: File.exists?(Path.join(root, "vlt_a"))
               } == %{
                 beside: {:error, {:refused, "conflict"}},
                 another_home: :ok,
                 landed: true,
                 again: :ok,
                 folder: op == :home_reset
               }
      end
    end

    test "home_retire is never ok beside a reset, which makes the home again",
         %{root: root, uid: uid} do
      %{name: name, fake: fake} = kept_client(root)
      assert {:ok, ^uid} = Keeper.home_ensure(name, "vlt_a")

      # The reset out, unanswered.
      :sys.suspend(fake)
      resetting = Task.async(fn -> Keeper.home_reset(name, "vlt_a") end)
      Prima.Test.Wait.wait_until(fn -> :sys.get_state(name).homes != %{} end, 5_000)
      beside_reset = Keeper.home_retire(name, "vlt_a")
      :sys.resume(fake)
      assert :ok = Task.await(resetting, 5_000)
      made_again = File.exists?(Path.join(root, "vlt_a"))

      assert %{beside_reset: beside_reset, made_again: made_again} == %{
               beside_reset: {:error, {:refused, "conflict"}},
               made_again: true
             }

      assert :ok = Keeper.home_retire(name, "vlt_a")
      refute File.exists?(Path.join(root, "vlt_a"))
    end

    test "a keeper that keeps no homes refuses every home and kept spawn as unavailable" do
      %{name: name, fake: fake} = FakeKeeper.start_client!()

      for call <- [
            &Keeper.home_ensure/2,
            &Keeper.home_measure/2,
            &Keeper.home_reset/2,
            &Keeper.home_retire/2
          ],
          do: assert({:error, {:refused, "unavailable"}} = call.(name, "vlt_a"))

      assert {:error, {:refused, "unavailable"}} = Keeper.home_list(name)

      assert {:error, {:refused, "unavailable"}} =
               Keeper.spawn(name, %{
                 argv: ["true"],
                 env: %{},
                 place: place!(name),
                 pool: "backends",
                 memory_bytes: 268_435_456,
                 cpu_quota: 100_000,
                 home: "vlt_a"
               })

      # The client asks cyfr-locus, which alone knows it keeps no homes.
      assert home_requests(fake) |> Enum.map(& &1["type"]) ==
               ~w(home_make home_measure home_reset home_retire home_list)
    end
  end

  # The fake relay's last word once it says nothing more for a while: what
  # it was doing, and the bytes it had written.
  defp quiet(last \\ {:none, 0}) do
    receive do
      {:fake_relay, kind, sent} -> quiet({kind, sent})
    after
      500 -> last
    end
  end
end
