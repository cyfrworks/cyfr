# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.KeeperVectorsTest do
  @moduledoc """
  `Locus.Keeper` against the keeper's shared vectors
  (`tests/fixtures/keeper_protocol.json`, which cyfr-keeper and its other
  clients reproduce), the test process holding the keeper's end of the
  channel, replying with the vectors' own lines and dialling as a spawn's
  relay with the vectors' frames: the spawn this client writes is the
  vectors' bounded build spawn, byte for byte but for its own id and
  attach target; every reply category the vectors hold is understood as
  they say, an unsolicited `pool` reply ignored; a reply of the wrong
  shape is ignored; every stream a relay never sends this client (stdin,
  the attach stream past the handshake and the control stream of a spawn
  that asked for none), an oversized frame and one on no stream end the
  run as a relay fault; and an attach frame of the wrong shape is closed.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Locus.Keeper
  alias Locus.Test.FakeKeeper
  alias Prima.KeeperProtocol

  # Read as this module compiles, so a checkout without the file fails
  # here, naming it, rather than running without the vectors.
  @vectors Path.expand("../../../../tests/fixtures/keeper_protocol.json", __DIR__)
           |> File.read!()
           |> Jason.decode!()

  # The reply categories this module's tests exercise: a category the
  # vectors gain fails here until a test hears it.
  @reply_categories [
    {"spawned", nil},
    {"error", "capacity"},
    {"error", "memory_unavailable"},
    {"error", "unknown_spawn"},
    {"exited", :status},
    {"exited", :signal},
    {"exited", :memory_exceeded},
    {"released", nil},
    {"pool", nil}
  ]

  setup do
    {peer, channel} = channel_pair()
    attach_dir = FakeKeeper.short_tmp_dir()
    name = :"spawner_vectors_#{System.unique_integer([:positive])}"
    {:ok, client} = Keeper.start_link(channel: channel, attach_dir: attach_dir, name: name)
    Process.unlink(client)
    :ok = :socket.setopt(channel, {:otp, :controlling_process}, client)
    Process.put(:peer_buffer, "")

    on_exit(fn ->
      Process.exit(client, :kill)
      File.rm_rf!(attach_dir)
    end)

    {:ok, v: @vectors, peer: peer, name: name, client: client}
  end

  # A run of `command`, answered with the log lines it produced.
  defp run(name, command \\ %{argv: ["/bin/sh", "-c", "true"], env: %{}}) do
    lines = Agent.start_link(fn -> [] end) |> elem(1)

    result =
      Keeper.run(name, Map.put(command, :stdin, ""),
        timeout_ms: 10_000,
        max_stdout_bytes: 1_000_000,
        on_output: fn line -> Agent.update(lines, &[line | &1]) end
      )

    {result, Agent.get(lines, &Enum.reverse/1)}
  end

  test "every reply category the vectors hold is one this module hears" do
    categories =
      @vectors["replies"]
      |> Enum.map(fn
        %{"type" => "error", "code" => code} -> {"error", code}
        %{"type" => "exited", "memory_exceeded" => true} -> {"exited", :memory_exceeded}
        %{"type" => "exited", "signal" => nil} -> {"exited", :status}
        %{"type" => "exited"} -> {"exited", :signal}
        %{"type" => type} -> {type, nil}
      end)
      |> Enum.uniq()
      |> Enum.sort()

    assert categories == Enum.sort(@reply_categories)
  end

  test "the spawn is the vectors' bounded build spawn, byte for byte", %{peer: peer, name: name} do
    vector =
      Enum.find(
        @vectors["valid_requests"],
        &(&1["pool"] == "build" and &1["memory_bytes"] == Locus.Config.memory_bytes())
      ) || flunk("no build spawn at the builder's bound among the vectors")

    refute Map.has_key?(vector, "control")
    task = Task.async(fn -> run(name, %{argv: vector["argv"], env: vector["env"]}) end)
    line = next_line(peer)
    sent = Jason.decode!(line)

    assert line ==
             Jason.encode!(%{vector | "id" => sent["id"], "attach" => sent["attach"]}) <> "\n"

    send_reply(peer, %{v: 1, type: "error", id: sent["id"], code: "capacity"})
    assert {{:error, :capacity}, []} = Task.await(task, 10_000)
  end

  test "the spawned, exited and released replies and the relay's frames complete a run", %{
    v: v,
    peer: peer,
    name: name,
    client: client
  } do
    task = Task.async(fn -> run(name) end)
    request = next_request(peer)
    assert %{"type" => "spawn", "pool" => "build"} = request

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
    v: v,
    peer: peer,
    name: name,
    client: client
  } do
    task = Task.async(fn -> run(name) end)
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
    v: v,
    peer: peer,
    name: name,
    client: client
  } do
    assert Enum.all?(
             v["replies"],
             &(&1["type"] != "exited" or is_boolean(&1["memory_exceeded"]))
           )

    task = Task.async(fn -> run(name) end)
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
       %{v: v, peer: peer, name: name} do
    task = Task.async(fn -> run(name) end)
    request = next_request(peer)

    refusal =
      v |> reply("error", &(&1["code"] == "memory_unavailable")) |> Map.put("id", request["id"])

    send_reply(peer, refusal)

    assert {{:error, {:unavailable, sentence}}, []} = Task.await(task, 10_000)
    assert sentence =~ "writable-cgroups=true"
  end

  test "the capacity refusal answers the run as capacity", %{v: v, peer: peer, name: name} do
    task = Task.async(fn -> run(name) end)
    request = next_request(peer)
    refusal = v |> reply("error", &(&1["code"] == "capacity")) |> Map.put("id", request["id"])
    send_reply(peer, refusal)

    assert {{:error, :capacity}, []} = Task.await(task, 10_000)
  end

  test "an unknown_spawn error for a spawn's release settles it as retired", %{
    v: v,
    peer: peer,
    name: name,
    client: client
  } do
    task = Task.async(fn -> run(name) end)
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

  test "a reply of the wrong shape is ignored, and the right one still heard", %{
    v: v,
    peer: peer,
    name: name,
    client: client
  } do
    task = Task.async(fn -> run(name) end)
    request = next_request(peer)
    send_reply(peer, v |> reply("spawned") |> Map.put("id", request["id"]))
    conn = attach(v, :sys.get_state(client).attach_path, request["attach"]["token"])
    :ok = :gen_tcp.close(conn)

    exited = reply(v, "exited", &(&1["signal"] == nil))

    log =
      capture_log(fn ->
        send_reply(peer, %{exited | "signal" => "SIGKILL"})
        send_reply(peer, Map.delete(exited, "memory_exceeded"))
        send_reply(peer, Map.delete(v |> reply("released"), "spawn_id"))
        send_reply(peer, exited)
        send_reply(peer, reply(v, "released"))
        assert {{:ok, %{exit: {:status, 1}}}, []} = Task.await(task, 10_000)
      end)

    assert log =~ "ambiguous_exit"
    assert log =~ "missing_field"
  end

  test "a frame on a stream a relay never sends this client, oversized or on no stream, ends the run as a relay fault",
       %{v: v, peer: peer, name: name, client: client} do
    refused = [frame_vector(v, "frames", 0), frame_vector(v, "frames", 3) | v["control_frames"]]
    assert Enum.map(refused, & &1["stream"]) == [0, 3, 4, 4]

    faults =
      Enum.map(refused, &encoded/1) ++
        [<<1, KeeperProtocol.max_frame_bytes() + 1::32>>, <<5, 0::32>>]

    for bytes <- faults do
      task = Task.async(fn -> run(name) end)
      request = next_request(peer)
      spawned = v |> reply("spawned") |> Map.put("id", request["id"])
      send_reply(peer, spawned)
      conn = attach(v, :sys.get_state(client).attach_path, request["attach"]["token"])
      :ok = :gen_tcp.send(conn, bytes)

      # The client closes the connection and releases the spawn at once.
      await_closed(conn)
      release = next_request(peer)
      assert %{"type" => "release", "grace_ms" => 0} = release
      assert release["spawn_id"] == spawned["spawn_id"]
      send_reply(peer, reply(v, "released"))

      assert {{:error, {:spawn_failed, :relay_protocol}}, []} = Task.await(task, 10_000)
    end
  end

  test "an attach frame of the wrong shape is closed", %{client: client} do
    path = :sys.get_state(client).attach_path
    token = String.duplicate("ab", 32)

    for bytes <- [<<1, 64::32>> <> token, <<3, 64::32>> <> String.upcase(token)] do
      {:ok, conn} = :gen_tcp.connect({:local, path}, 0, [:binary, active: false])
      :ok = :gen_tcp.send(conn, bytes)
      assert {:error, :closed} = :gen_tcp.recv(conn, 0, 5_000)
    end
  end

  # ————— the far end of the channel —————

  # A connected pair of `:socket`s: the peer's end, held by the test
  # process, and the client's, handed to `Locus.Keeper`.
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

  # The next line the client wrote, raw, with its newline; bytes past it
  # wait in the process dictionary for the next call.
  defp next_line(peer) do
    case String.split(Process.get(:peer_buffer, ""), "\n", parts: 2) do
      [line, rest] ->
        Process.put(:peer_buffer, rest)
        line <> "\n"

      [partial] ->
        {:ok, data} = :socket.recv(peer, 0, 5_000)
        Process.put(:peer_buffer, partial <> data)
        next_line(peer)
    end
  end

  defp next_request(peer), do: peer |> next_line() |> Jason.decode!()

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
