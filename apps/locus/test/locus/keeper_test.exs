# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.KeeperTest do
  @moduledoc """
  The client side of cyfr-keeper's protocol. Against a fake keeper
  (`Locus.Test.FakeKeeper`): a run delivers stdin, answers stdout, the log
  line by line and the exit, and returns only after the spawn is reported
  released; every spawn asks for the builder's memory bound, and there is
  no asking for none; the deadline, a stdout bound, a cancel and the
  caller's death release the spawn with no grace; a relay connection that
  arrives after the release report still delivers its output; a refused
  spawn and a lost channel answer at once; a spawn ended at its bound is
  the wire's `memory` refusal and a bound that cannot be enforced its
  `unavailable`, naming the option the deployment lacks. A long-lived
  spawn (`Locus.Launcher`) answers its handle, and its owner hears the
  relay attached, its stdout and stderr apart and its exit, then its
  release, the last; stdin goes as frames of the codec's bound; `signal`,
  `release` with a grace and `pool` are the vectors' requests, byte for
  byte but for their own ids; an owner that dies has its spawn released
  with no grace; a request the keeper would refuse is refused before it
  is sent. The build spawn's vectors are `Locus.KeeperVectorsTest`'s.
  Whether a real spawn is isolated is the builder image tests' to prove.
  """

  use ExUnit.Case, async: false

  alias Locus.Keeper
  alias Locus.Test.FakeKeeper
  alias Prima.KeeperProtocol

  @vectors Path.expand("../../../../tests/fixtures/keeper_protocol.json", __DIR__)
           |> File.read!()
           |> Jason.decode!()

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
          timeout_ms: Keyword.get(opts, :timeout_ms, 10_000),
          max_stdout_bytes: Keyword.get(opts, :max_stdout_bytes, 1_000_000),
          on_output: fn line -> Agent.update(lines, &[line | &1]) end
        ] ++ Keyword.take(opts, [:memory_bytes])
      )

    {result, Agent.get(lines, &Enum.reverse/1)}
  end

  defp wait_until(check, attempts \\ 100) do
    cond do
      check.() -> :ok
      attempts == 0 -> flunk("condition never held")
      true -> Process.sleep(50) && wait_until(check, attempts - 1)
    end
  end

  describe "against the fake keeper" do
    setup do
      {fake, channel} = FakeKeeper.start()
      attach_dir = FakeKeeper.short_tmp_dir()
      name = :"spawner_#{System.unique_integer([:positive])}"
      {:ok, client} = Keeper.start_link(channel: channel, attach_dir: attach_dir, name: name)
      Process.unlink(client)
      :ok = :socket.setopt(channel, {:otp, :controlling_process}, client)

      on_exit(fn ->
        Process.exit(client, :kill)
        Process.exit(fake, :kill)
        File.rm_rf!(attach_dir)
      end)

      {:ok, fake: fake, name: name, client: client}
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
      wait_until(fn -> releases(fake, grace) != [] end)
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

    test "every spawn asks for the builder's memory bound, and none can ask for no bound", %{
      name: name,
      fake: fake
    } do
      assert {{:ok, _}, _} = run(name, "true")
      assert {{:ok, _}, _} = run(name, "true", memory_bytes: 33_554_432)

      Application.put_env(:locus, :memory_bytes, 268_435_456)
      on_exit(fn -> Application.delete_env(:locus, :memory_bytes) end)
      assert {{:ok, _}, _} = run(name, "true")

      spawns = fake |> FakeKeeper.requests() |> Enum.filter(&(&1["type"] == "spawn"))
      assert Enum.map(spawns, & &1["memory_bytes"]) == [1_073_741_824, 33_554_432, 268_435_456]

      for none <- [nil, 0, -1, "1G"] do
        assert_raise ArgumentError, ~r/memory bound/, fn ->
          run(name, "true", memory_bytes: none)
        end
      end

      assert length(Enum.filter(FakeKeeper.requests(fake), &(&1["type"] == "spawn"))) == 3
    end

    test "a spawn ended at its memory bound answers the wire's memory refusal with the bound", %{
      name: name,
      fake: fake
    } do
      :ok =
        FakeKeeper.mode(fake, {:exit, %{code: nil, signal: "SIGKILL", memory_exceeded: true}})

      assert {{:error, {:memory, 33_554_432}}, ["the command's last words"]} =
               run(name, "true", memory_bytes: 33_554_432)

      # The same end without the kernel's report is a signal like any other.
      :ok =
        FakeKeeper.mode(fake, {:exit, %{code: nil, signal: "SIGKILL", memory_exceeded: false}})

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
      assert {:ok, _} = Prima.BuilderProtocol.encode_refusal({:unavailable, sentence}, [])
    end

    test "a cancelled run releases the spawn with no grace and answers cancelled", %{
      name: name,
      fake: fake
    } do
      test = self()
      runner = spawn_link(fn -> send(test, {:answer, run(name, "exec sleep 30")}) end)
      wait_until(fn -> Enum.any?(FakeKeeper.requests(fake), &(&1["type"] == "spawn")) end)
      Process.sleep(200)

      :ok = Locus.Executor.cancel(runner)

      assert_receive {:answer, {{:error, :cancelled}, _lines}}, 10_000
      assert [_] = awaited_releases(fake, 0)
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
      wait_until(fn -> releases(fake, 0) != [] or FakeKeeper.exits(fake) != [] end)

      if FakeKeeper.exits(fake) == [] do
        assert [_] = releases(fake, 0)
      end
    end

    test "a caller that dies has its spawn released", %{name: name, fake: fake} do
      caller = spawn(fn -> run(name, "exec sleep 30") end)
      wait_until(fn -> Enum.any?(FakeKeeper.requests(fake), &(&1["type"] == "spawn")) end)
      Process.sleep(200)
      Process.exit(caller, :kill)

      wait_until(fn -> releases(fake, 0) != [] end)
    end

    test "a relay that connects after the release report still delivers its output", %{
      name: name,
      fake: fake
    } do
      :ok = FakeKeeper.mode(fake, :report_first)
      {result, _lines} = run(name, "echo late")

      assert {:ok, %{exit: {:status, 0}, stdout: "late\n"}} = result
    end

    test "a spawn the pool cannot hold is refused as capacity", %{name: name, fake: fake} do
      :ok = FakeKeeper.mode(fake, :capacity)
      assert {{:error, :capacity}, []} = run(name, "true")
    end

    test "losing the channel ends the client and answers a waiting run", %{
      name: name,
      fake: fake,
      client: client
    } do
      ref = Process.monitor(client)
      task = Task.async(fn -> run(name, "exec sleep 30") end)
      wait_until(fn -> Enum.any?(FakeKeeper.requests(fake), &(&1["type"] == "spawn")) end)

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
      File.chmod!(dir, 0o755)
      {_fake, channel} = FakeKeeper.start()

      assert {:error, {:spawner_unavailable, {:attach_dir_not_private, ^dir}}} =
               Keeper.start_link(channel: channel, attach_dir: dir, name: :spawner_open_dir)

      File.rm_rf!(dir)
    end

    test "fd 3 is the channel only when it is the socket cyfr-keeper names" do
      previous = System.get_env("KEEPER_CHANNEL")

      on_exit(fn ->
        if previous,
          do: System.put_env("KEEPER_CHANNEL", previous),
          else: System.delete_env("KEEPER_CHANNEL")
      end)

      System.delete_env("KEEPER_CHANNEL")
      refute Keeper.channel_inherited?()

      System.put_env("KEEPER_CHANNEL", "socket:[1]")
      refute Keeper.channel_inherited?()
    end
  end

  describe "a long-lived spawn against the fake keeper" do
    setup do
      {fake, channel} = FakeKeeper.start()
      attach_dir = FakeKeeper.short_tmp_dir()
      name = :"keeper_#{System.unique_integer([:positive])}"
      {:ok, client} = Keeper.start_link(channel: channel, attach_dir: attach_dir, name: name)
      Process.unlink(client)
      :ok = :socket.setopt(channel, {:otp, :controlling_process}, client)

      on_exit(fn ->
        Process.exit(client, :kill)
        Process.exit(fake, :kill)
        File.rm_rf!(attach_dir)
      end)

      {:ok, fake: fake, name: name, client: client}
    end

    defp spawn_live(name, script, env \\ %{}) do
      Keeper.spawn(name, %{
        argv: ["/bin/sh", "-c", script],
        env: env,
        pool: "backends",
        memory_bytes: 268_435_456
      })
    end

    # The events of `handle` until its release, the last, in order, with
    # stdout and stderr each joined where they arrived in pieces.
    defp events_until_released(%{ref: ref}, acc \\ []) do
      receive do
        {Keeper, ^ref, :released} -> joined(Enum.reverse([:released | acc]))
        {Keeper, ^ref, event} -> events_until_released(%{ref: ref}, [event | acc])
      after
        10_000 -> flunk("no release; heard #{length(acc)} events")
      end
    end

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
      wait_until(fn -> requests(fake, type) != [] end)
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
      assert {:stdout, "out\n"} in events
      assert {:stderr, "hello\n"} in events
      assert Enum.take(events, -2) == [{:exited, 4, nil}, :released]

      [spawn] = recorded(fake, "spawn")
      assert spawn["pool"] == "backends"
      assert spawn["memory_bytes"] == 268_435_456
      assert spawn["env"] == %{"GREETING" => "hello"}

      # Nothing is heard of a spawn after its release.
      refute_receive {Keeper, _ref, _event}, 200
    end

    test "a spawn's memory bound is its spec's, and a spec may name none", %{
      name: name,
      fake: fake
    } do
      assert {:ok, handle} =
               Keeper.spawn(name, %{argv: ["true"], env: %{}, pool: "backends"})

      events_until_released(handle)
      [spawn] = recorded(fake, "spawn")
      refute Map.has_key?(spawn, "memory_bytes")
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
      assert {:exited, 0, nil} in events
    end

    test "signal signals the spawn and is the vectors' request", %{name: name, fake: fake} do
      assert {:ok, handle} = spawn_live(name, "echo ready; exec sleep 30")
      assert_receive {Keeper, _ref, {:stdout, "ready\n"}}, 10_000

      assert {:error, :unencodable} = Keeper.signal(handle, "SIGSTOP")
      assert :ok = Keeper.signal(handle, "SIGTERM")

      assert Enum.take(events_until_released(handle), -2) == [
               {:exited, nil, "SIGTERM"},
               :released
             ]

      [signal] = recorded(fake, "signal")
      vector = Enum.find(@vectors["valid_requests"], &(&1["type"] == "signal"))
      assert signal == %{vector | "spawn_id" => handle.spawn_id}

      assert {:error, :unknown_spawn} = Keeper.signal(handle, "SIGTERM")
    end

    test "release with a grace lets the spawn end on its own, and is the vectors' request", %{
      name: name,
      fake: fake
    } do
      script = ~s(trap 'echo term; exit 0' TERM; echo ready; while :; do sleep 0.1; done)
      assert {:ok, handle} = spawn_live(name, script)
      assert_receive {Keeper, _ref, {:stdout, "ready\n"}}, 10_000

      assert :ok = Keeper.release(name, handle, 2_000)
      events = events_until_released(handle)
      assert {:stdout, "term\n"} in events
      assert {:exited, 0, nil} in events

      [release] = recorded(fake, "release")
      vector = Enum.find(@vectors["valid_requests"], &(&1["type"] == "release"))
      assert release == %{vector | "spawn_id" => handle.spawn_id}
    end

    test "release with no grace kills the spawn", %{name: name, fake: fake} do
      assert {:ok, handle} = spawn_live(name, "echo ready; exec sleep 30")
      assert_receive {Keeper, _ref, {:stdout, "ready\n"}}, 10_000

      :ok = Keeper.release(name, handle, 0)

      assert Enum.take(events_until_released(handle), -2) == [
               {:exited, nil, "SIGKILL"},
               :released
             ]

      assert [%{"grace_ms" => 0}] = recorded(fake, "release")
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

      wait_until(fn -> Enum.any?(requests(fake, "release"), &(&1["grace_ms"] == 0)) end)
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

    test "a keeper that is gone answers as unavailable" do
      assert {:error, {:launcher_unavailable, :noproc}} =
               Keeper.spawn(:no_such_keeper, %{argv: ["true"], env: %{}, pool: "backends"})

      assert {:error, {:launcher_unavailable, :noproc}} =
               Keeper.pool_stats(:no_such_keeper, "backends")
    end

    test "losing the channel reports every long-lived spawn released", %{
      name: name,
      fake: fake
    } do
      assert {:ok, handle} = spawn_live(name, "exec sleep 30")
      assert_receive {Keeper, _ref, :attached}, 10_000
      ref = handle.ref

      :ok = FakeKeeper.close(fake)
      assert_receive {Keeper, ^ref, :released}, 5_000
    end
  end
end
