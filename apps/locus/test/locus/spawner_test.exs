# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.SpawnerTest do
  @moduledoc """
  The client side of cyfr-spawn's protocol. Against a fake spawner
  (`Locus.Test.FakeSpawner`): a run delivers stdin, answers stdout, the log
  line by line and the exit, and returns only after the spawn is reported
  released; every spawn asks for the builder's memory bound, and there is
  no asking for none; the deadline, a stdout bound, a cancel and the
  caller's death release the spawn with no grace; a relay connection that
  arrives after the release report still delivers its output; a refused
  spawn and a lost channel answer at once; a spawn ended at its bound is
  the wire's `memory` refusal and a bound that cannot be enforced its
  `unavailable`, naming the option the deployment lacks. Against the shared
  vectors
  (`tests/fixtures/spawn_protocol.json`, which the spawner and its other
  clients reproduce): every reply is understood as the vectors say, and
  every frame stream is read as they encode it, the control stream of a
  spawn with a control channel, which this client never asks for, being
  refused. Whether a real spawn is isolated is the builder image tests' to
  prove.
  """

  use ExUnit.Case, async: false

  alias Locus.Spawner
  alias Locus.Test.FakeSpawner

  @vectors_path Path.expand("../../../../tests/fixtures/spawn_protocol.json", __DIR__)

  defp run(name, script, opts \\ []) do
    lines = Agent.start_link(fn -> [] end) |> elem(1)

    result =
      Spawner.run(
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

  describe "against the fake spawner" do
    setup do
      {fake, channel} = FakeSpawner.start()
      attach_dir = FakeSpawner.short_tmp_dir()
      name = :"spawner_#{System.unique_integer([:positive])}"
      {:ok, client} = Spawner.start_link(channel: channel, attach_dir: attach_dir, name: name)
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
      |> FakeSpawner.requests()
      |> Enum.filter(&(&1["type"] == "release" and &1["grace_ms"] == grace))
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

      [spawn] = fake |> FakeSpawner.requests() |> Enum.filter(&(&1["type"] == "spawn"))
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

      spawns = fake |> FakeSpawner.requests() |> Enum.filter(&(&1["type"] == "spawn"))
      assert Enum.map(spawns, & &1["memory_bytes"]) == [1_073_741_824, 33_554_432, 268_435_456]

      for none <- [nil, 0, -1, "1G"] do
        assert_raise ArgumentError, ~r/memory bound/, fn ->
          run(name, "true", memory_bytes: none)
        end
      end

      assert length(Enum.filter(FakeSpawner.requests(fake), &(&1["type"] == "spawn"))) == 3
    end

    test "a spawn ended at its memory bound answers the wire's memory refusal with the bound", %{
      name: name,
      fake: fake
    } do
      :ok =
        FakeSpawner.mode(fake, {:exit, %{code: nil, signal: "SIGKILL", memory_exceeded: true}})

      assert {{:error, {:memory, 33_554_432}}, ["the command's last words"]} =
               run(name, "true", memory_bytes: 33_554_432)

      # The same end without the kernel's report is a signal like any other.
      :ok =
        FakeSpawner.mode(fake, {:exit, %{code: nil, signal: "SIGKILL", memory_exceeded: false}})

      assert {{:ok, %{exit: {:signal, "SIGKILL"}}}, _} = run(name, "true")
    end

    test "a spawner that cannot enforce the bound runs nothing: unavailable, naming the option",
         %{
           name: name,
           fake: fake
         } do
      :ok = FakeSpawner.mode(fake, :memory_unavailable)

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
      wait_until(fn -> Enum.any?(FakeSpawner.requests(fake), &(&1["type"] == "spawn")) end)
      Process.sleep(200)

      :ok = Locus.Executor.cancel(runner)

      assert_receive {:answer, {{:error, :cancelled}, _lines}}, 10_000
      assert [_] = releases(fake, 0)
    end

    test "a run past its deadline releases the spawn with no grace", %{name: name, fake: fake} do
      started = System.monotonic_time(:millisecond)
      # The fake kills the command's PID; exec avoids a shell-owned child.
      {result, _lines} = run(name, "exec sleep 30", timeout_ms: 300)

      assert result == {:error, :timeout}
      assert System.monotonic_time(:millisecond) - started < 10_000
      assert [_] = releases(fake, 0)
    end

    test "stdout past its bound releases the spawn", %{name: name, fake: fake} do
      {result, _lines} = run(name, "head -c 5000 /dev/zero", max_stdout_bytes: 1_000)

      assert result == {:error, {:output_too_large, 1_000}}
      assert [_] = releases(fake, 0)
    end

    test "a caller that dies has its spawn released", %{name: name, fake: fake} do
      caller = spawn(fn -> run(name, "exec sleep 30") end)
      wait_until(fn -> Enum.any?(FakeSpawner.requests(fake), &(&1["type"] == "spawn")) end)
      Process.sleep(200)
      Process.exit(caller, :kill)

      wait_until(fn -> releases(fake, 0) != [] end)
    end

    test "a relay that connects after the release report still delivers its output", %{
      name: name,
      fake: fake
    } do
      :ok = FakeSpawner.mode(fake, :report_first)
      {result, _lines} = run(name, "echo late")

      assert {:ok, %{exit: {:status, 0}, stdout: "late\n"}} = result
    end

    test "a spawn the pool cannot hold is refused as capacity", %{name: name, fake: fake} do
      :ok = FakeSpawner.mode(fake, :capacity)
      assert {{:error, :capacity}, []} = run(name, "true")
    end

    test "losing the channel ends the client and answers a waiting run", %{
      name: name,
      fake: fake,
      client: client
    } do
      ref = Process.monitor(client)
      task = Task.async(fn -> run(name, "exec sleep 30") end)
      wait_until(fn -> Enum.any?(FakeSpawner.requests(fake), &(&1["type"] == "spawn")) end)

      :ok = FakeSpawner.close(fake)

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
      dir = FakeSpawner.short_tmp_dir()
      File.chmod!(dir, 0o755)
      {_fake, channel} = FakeSpawner.start()

      assert {:error, {:spawner_unavailable, {:attach_dir_not_private, ^dir}}} =
               Spawner.start_link(channel: channel, attach_dir: dir, name: :spawner_open_dir)

      File.rm_rf!(dir)
    end

    test "fd 3 is the channel only when it is the socket cyfr-spawn names" do
      previous = System.get_env("CYFR_SPAWN_CHANNEL")

      on_exit(fn ->
        if previous,
          do: System.put_env("CYFR_SPAWN_CHANNEL", previous),
          else: System.delete_env("CYFR_SPAWN_CHANNEL")
      end)

      System.delete_env("CYFR_SPAWN_CHANNEL")
      refute Spawner.channel_inherited?()

      System.put_env("CYFR_SPAWN_CHANNEL", "socket:[1]")
      refute Spawner.channel_inherited?()
    end
  end

  # The test process is the far end of the channel here, replying with the
  # vectors' own lines and connecting as a relay with the vectors' frames.
  describe "against the shared vectors" do
    setup do
      vectors = @vectors_path |> File.read!() |> Jason.decode!()
      {peer, channel} = channel_pair()
      attach_dir = FakeSpawner.short_tmp_dir()
      name = :"spawner_vectors_#{System.unique_integer([:positive])}"
      {:ok, client} = Spawner.start_link(channel: channel, attach_dir: attach_dir, name: name)
      Process.unlink(client)
      :ok = :socket.setopt(channel, {:otp, :controlling_process}, client)
      Process.put(:peer_buffer, "")

      on_exit(fn ->
        Process.exit(client, :kill)
        File.rm_rf!(attach_dir)
      end)

      {:ok, vectors: vectors, peer: peer, name: name, client: client}
    end

    test "the spawned, exited and released replies and the relay's frames complete a run", %{
      vectors: v,
      peer: peer,
      name: name,
      client: client
    } do
      task = Task.async(fn -> run(name, "true") end)
      request = next_request(peer)
      assert %{"type" => "spawn", "pool" => "build"} = request

      # The spawn this client writes is the vectors' bounded build spawn,
      # field for field, its bound within the range the spawner accepts.
      vector =
        Enum.find(
          v["valid_requests"],
          &(&1["pool"] == "build" and &1["memory_bytes"] == 1_073_741_824)
        )

      assert Map.keys(request) |> Enum.sort() == Map.keys(vector) |> Enum.sort()
      assert request["memory_bytes"] == vector["memory_bytes"]

      # A pool reply, which this client never asks for, is understood and
      # ignored.
      send_reply(peer, reply(v, "pool"))
      spawned = v |> reply("spawned") |> Map.put("id", request["id"])
      send_reply(peer, spawned)

      conn = attach(v, :sys.get_state(client).attach_path, request["attach"]["token"])
      stdout = frame_vector(v, "frames", 1)
      stderr_end = frame_vector(v, "frames", 2)
      assert payload(stdout) == "hello" and payload(stderr_end) == ""
      :ok = :gen_tcp.send(conn, [encoded(stdout), encoded(stderr_end)])
      :ok = :gen_tcp.close(conn)

      exited = reply(v, "exited", &(&1["signal"] == nil))
      assert exited["spawn_id"] == spawned["spawn_id"] and exited["code"] == 1
      send_reply(peer, exited)
      send_reply(peer, reply(v, "released"))

      assert {{:ok, %{exit: {:status, 1}, stdout: "hello"}}, []} = Task.await(task, 10_000)
    end

    test "an exit by signal is answered as the signal", %{
      vectors: v,
      peer: peer,
      name: name,
      client: client
    } do
      task = Task.async(fn -> run(name, "true") end)
      request = next_request(peer)
      send_reply(peer, v |> reply("spawned") |> Map.put("id", request["id"]))
      conn = attach(v, :sys.get_state(client).attach_path, request["attach"]["token"])
      :ok = :gen_tcp.close(conn)

      exited = reply(v, "exited", &(&1["signal"] != nil and not &1["memory_exceeded"]))
      assert exited["code"] == nil and exited["signal"] == "SIGKILL"
      send_reply(peer, exited)
      send_reply(peer, reply(v, "released"))

      assert {{:ok, %{exit: {:signal, "SIGKILL"}, stdout: ""}}, []} = Task.await(task, 10_000)
    end

    test "an exit reported at the memory bound answers the run as the wire's memory refusal", %{
      vectors: v,
      peer: peer,
      name: name,
      client: client
    } do
      assert Enum.all?(
               v["replies"],
               &(&1["type"] != "exited" or is_boolean(&1["memory_exceeded"]))
             )

      task = Task.async(fn -> run(name, "true") end)
      request = next_request(peer)
      assert request["memory_bytes"] == Locus.Config.memory_bytes()
      send_reply(peer, v |> reply("spawned") |> Map.put("id", request["id"]))
      conn = attach(v, :sys.get_state(client).attach_path, request["attach"]["token"])
      :ok = :gen_tcp.close(conn)

      exited = reply(v, "exited", & &1["memory_exceeded"])
      assert exited["code"] == nil and exited["signal"] == "SIGKILL"
      send_reply(peer, exited)
      send_reply(peer, reply(v, "released"))

      assert {{:error, {:memory, limit}}, []} = Task.await(task, 10_000)
      assert limit == request["memory_bytes"]
    end

    test "the refusal of a bound that cannot be enforced answers the run as the wire's unavailable",
         %{
           vectors: v,
           peer: peer,
           name: name
         } do
      task = Task.async(fn -> run(name, "true") end)
      request = next_request(peer)

      refusal =
        v |> reply("error", &(&1["code"] == "memory_unavailable")) |> Map.put("id", request["id"])

      send_reply(peer, refusal)

      assert {{:error, {:unavailable, sentence}}, []} = Task.await(task, 10_000)
      assert sentence =~ "writable-cgroups=true"
    end

    test "the capacity refusal answers the run as capacity", %{
      vectors: v,
      peer: peer,
      name: name
    } do
      task = Task.async(fn -> run(name, "true") end)
      request = next_request(peer)
      refusal = v |> reply("error", &(&1["code"] == "capacity")) |> Map.put("id", request["id"])
      send_reply(peer, refusal)

      assert {{:error, :capacity}, []} = Task.await(task, 10_000)
    end

    test "an unknown_spawn error for a spawn's release settles it as retired", %{
      vectors: v,
      peer: peer,
      name: name,
      client: client
    } do
      task = Task.async(fn -> run(name, "true") end)
      request = next_request(peer)
      spawned = v |> reply("spawned") |> Map.put("id", request["id"])
      send_reply(peer, spawned)
      conn = attach(v, :sys.get_state(client).attach_path, request["attach"]["token"])
      :ok = :gen_tcp.close(conn)

      unknown = reply(v, "error", &(&1["code"] == "unknown_spawn"))
      assert unknown["spawn_id"] == spawned["spawn_id"]
      send_reply(peer, unknown)

      assert {{:error, {:spawn_failed, :no_exit_reported}}, []} = Task.await(task, 10_000)
    end

    test "a frame on a stream a relay never sends this client ends the run as a relay fault",
         %{vectors: v, peer: peer, name: name, client: client} do
      refused = [frame_vector(v, "frames", 0) | v["control_frames"]]
      assert Enum.map(refused, & &1["stream"]) == [0, 4, 4]

      for frame <- refused do
        task = Task.async(fn -> run(name, "true") end)
        request = next_request(peer)
        spawned = v |> reply("spawned") |> Map.put("id", request["id"])
        send_reply(peer, spawned)
        conn = attach(v, :sys.get_state(client).attach_path, request["attach"]["token"])
        :ok = :gen_tcp.send(conn, encoded(frame))

        # The client closes the connection and releases the spawn at once.
        await_closed(conn)
        release = next_request(peer)
        assert %{"type" => "release", "grace_ms" => 0} = release
        assert release["spawn_id"] == spawned["spawn_id"]
        send_reply(peer, reply(v, "released"))

        assert {{:error, {:spawn_failed, :relay_protocol}}, []} = Task.await(task, 10_000)
      end
    end
  end

  # ————— the far end of the channel —————

  # A connected pair of `:socket`s: the peer's end, held by the test
  # process, and the client's, handed to `Locus.Spawner`.
  defp channel_pair do
    dir = FakeSpawner.short_tmp_dir()
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

  # The next request the client wrote, decoded; bytes past it wait in the
  # process dictionary for the next call.
  defp next_request(peer) do
    case String.split(Process.get(:peer_buffer, ""), "\n", parts: 2) do
      [line, rest] ->
        Process.put(:peer_buffer, rest)
        Jason.decode!(line)

      [partial] ->
        {:ok, data} = :socket.recv(peer, 0, 5_000)
        Process.put(:peer_buffer, partial <> data)
        next_request(peer)
    end
  end

  defp send_reply(peer, message), do: :ok = :socket.send(peer, [Jason.encode!(message), ?\n])

  defp reply(vectors, type, match \\ fn _reply -> true end) do
    Enum.find(vectors["replies"], &(&1["type"] == type and match.(&1))) ||
      flunk("no #{type} reply among the vectors")
  end

  defp frame_vector(vectors, key, stream),
    do:
      Enum.find(vectors[key], &(&1["stream"] == stream)) || flunk("no #{key} on stream #{stream}")

  defp encoded(frame), do: Base.decode16!(frame["encoded_hex"], case: :lower)
  defp payload(frame), do: Base.decode16!(frame["payload_hex"], case: :lower)

  # Connects as a spawn's relay would: the vectors' attach frame, whose
  # payload is this spawn's token, opens the connection.
  defp attach(vectors, attach_path, token) do
    attach_frame = frame_vector(vectors, "frames", 3)
    assert <<3, 64::32, _token::binary-size(64)>> = encoded(attach_frame)
    assert byte_size(token) == 64

    {:ok, conn} =
      :gen_tcp.connect({:local, attach_path}, 0, [:binary, active: false, packet: :raw])

    :ok = :gen_tcp.send(conn, <<3, 64::32>> <> token)
    conn
  end

  # Waits for the client to close the connection. Its stdin here is empty,
  # so the one frame it may send first is stdin's zero-length end frame,
  # written by a process of its own that the close may or may not follow.
  defp await_closed(conn) do
    case :gen_tcp.recv(conn, 0, 5_000) do
      {:error, :closed} ->
        :ok

      {:ok, data} ->
        assert data == <<0, 0::32>>
        await_closed(conn)
    end
  end
end
