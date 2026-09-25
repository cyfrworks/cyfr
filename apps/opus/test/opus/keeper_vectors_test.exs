# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.KeeperVectorsTest do
  @moduledoc """
  `Opus.Keeper.Channel` against the keeper's shared vectors
  (`tests/fixtures/keeper_protocol.json`), the test holding the keeper's
  end of the channel and dialling as a runner's relay: the spawn it
  writes is the vectors' bounded runner spawn with a control channel,
  byte for byte but for its own id, command and attach target; every
  reply the vectors hold reaches the spawn's handle as the event it
  means; a reply of the wrong shape is ignored; the relay's stdout,
  stderr and control frames are carried, and a frame on stdin or the
  attach stream, an oversized one or one on no stream is refused in band
  as a relay fault; and an attach frame of the wrong shape is closed.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Opus.Keeper.Channel
  alias Prima.KeeperProtocol

  # Read as this module compiles, so a checkout without the file fails
  # here, naming it, rather than running without the vectors.
  @vectors Path.expand("../../../../tests/fixtures/keeper_protocol.json", __DIR__)
           |> File.read!()
           |> Jason.decode!()

  @runner_spawn Enum.find(
                  @vectors["valid_requests"],
                  &(&1["pool"] == "runner" and &1["control"] == true and &1["memory_bytes"])
                )

  setup do
    {:ok, unique: System.unique_integer([:positive])}
  end

  # A client on a fresh channel, holding runners to `memory_bytes`: its
  # name, the keeper's end and the attach directory.
  defp start_client!(%{unique: unique}, memory_bytes \\ @runner_spawn["memory_bytes"]) do
    n = System.unique_integer([:positive])
    path = Path.join(System.tmp_dir!(), "opus_vectors_#{unique}_#{n}.sock")
    dir = Path.join(System.tmp_dir!(), "opus_vectors_attach_#{unique}_#{n}")
    File.rm(path)
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)

    {:ok, listener} = :socket.open(:local, :stream)
    :ok = :socket.bind(listener, %{family: :local, path: path})
    :ok = :socket.listen(listener)
    {:ok, keeper_end} = :socket.open(:local, :stream)
    :ok = :socket.connect(keeper_end, %{family: :local, path: path})
    {:ok, spawner} = :socket.accept(listener)
    name = :"opus_vectors_#{unique}_#{n}"

    start_supervised!(
      Supervisor.child_spec(
        {Channel, channel: keeper_end, attach_dir: dir, name: name, memory_bytes: memory_bytes},
        id: name,
        restart: :temporary
      )
    )

    on_exit(fn ->
      :socket.close(spawner)
      :socket.close(listener)
      File.rm(path)
      File.rm_rf(dir)
    end)

    %{name: name, spawner: spawner, dir: dir}
  end

  # Asks the client for a runner as the pool does; the test process owns
  # the spawn and hears its events.
  defp spawn!(client, argv \\ ["/app/bin/opus", "start"], env \\ %{"OPUS_ROLE" => "runner"}) do
    spec = %{runner: "runner_vectors", argv: argv, env: env, server: client.name}
    {:ok, %{ref: ref}, []} = Channel.spawn(spec)
    {line, ""} = raw_request(client.spawner)
    {ref, line}
  end

  # The next line the client wrote the keeper, raw, and what followed it.
  defp raw_request(spawner, buffer \\ "") do
    case :binary.split(buffer, "\n") do
      [line, rest] ->
        {line <> "\n", rest}

      [partial] ->
        {:ok, data} = :socket.recv(spawner, 0, 5_000)
        raw_request(spawner, partial <> data)
    end
  end

  defp reply(client, message),
    do: :ok = :socket.send(client.spawner, [Jason.encode!(message), ?\n])

  defp reply_vector(type, match) do
    Enum.find(@vectors["replies"], &(&1["type"] == type and match.(&1))) ||
      flunk("no #{type} reply among the vectors")
  end

  # The vectors' spawned reply, answering the request on `line`.
  defp spawned(client, line) do
    spawned = %{reply_vector("spawned", fn _ -> true end) | "id" => Jason.decode!(line)["id"]}
    reply(client, spawned)
    spawned
  end

  defp frame_vector(key, stream),
    do: Enum.find(@vectors[key], &(&1["stream"] == stream)) || flunk("no #{key} on #{stream}")

  defp encoded(frame), do: Base.decode16!(frame["encoded_hex"], case: :lower)
  defp payload(frame), do: Base.decode16!(frame["payload_hex"], case: :lower)

  defp attach!(client, line) do
    %{"attach" => %{"path" => path, "token" => token}} = Jason.decode!(line)
    assert path == Path.join(client.dir, "attach.sock")
    {:ok, relay} = :gen_tcp.connect({:local, path}, 0, [:binary, active: false])
    :ok = :gen_tcp.send(relay, KeeperProtocol.attach_frame(token))
    relay
  end

  test "the spawn is the vectors' bounded runner spawn with a control channel, byte for byte",
       ctx do
    assert %{"control" => true, "memory_bytes" => bound} = @runner_spawn
    client = start_client!(ctx)
    {_ref, line} = spawn!(client, @runner_spawn["argv"], @runner_spawn["env"])
    sent = Jason.decode!(line)

    # The vector with this client's own id and attach target is the line.
    expected = %{@runner_spawn | "id" => sent["id"], "attach" => sent["attach"]}
    assert line == Jason.encode!(expected) <> "\n"
    assert sent["memory_bytes"] == bound
    assert sent["attach"]["token"] =~ ~r/\A[0-9a-f]{64}\z/
  end

  test "every reply the vectors hold reaches the spawn's handle as the event it means", ctx do
    for vector <- @vectors["replies"] do
      client = start_client!(ctx)

      case vector do
        %{"type" => "spawned"} ->
          {ref, line} = spawn!(client)
          spawned = spawned(client, line)
          pid = spawned["pid"]
          assert_receive {Channel, ^ref, {:spawned, ^pid}}, 5_000

        %{"type" => "error", "id" => _id, "code" => "memory_unavailable"} ->
          {ref, line} = spawn!(client)

          log =
            capture_log(fn ->
              reply(client, %{vector | "id" => Jason.decode!(line)["id"]})
              assert_receive {Channel, ^ref, {:refused, :memory_unavailable}}, 5_000
            end)

          assert log =~ "writable-cgroups=true"

        %{"type" => "error", "id" => _id, "code" => code} ->
          {ref, line} = spawn!(client)
          reply(client, %{vector | "id" => Jason.decode!(line)["id"]})
          assert_receive {Channel, ^ref, {:refused, ^code}}, 5_000

        %{"type" => "error", "spawn_id" => spawn_id, "code" => "unknown_spawn"} ->
          {ref, line} = spawn!(client)
          assert spawned(client, line)["spawn_id"] == spawn_id
          reply(client, vector)
          assert_receive {Channel, ^ref, :released}, 5_000

        %{"type" => "exited", "spawn_id" => spawn_id} ->
          {ref, line} = spawn!(client)
          assert spawned(client, line)["spawn_id"] == spawn_id

          how =
            if vector["signal"],
              do: {:signal, vector["signal"]},
              else: {:status, vector["code"]}

          log =
            capture_log(fn ->
              reply(client, vector)
              assert_receive {Channel, ^ref, {:exited, ^how}}, 5_000
            end)

          assert log =~ "memory bound" == vector["memory_exceeded"]

        %{"type" => "released", "spawn_id" => spawn_id} ->
          {ref, line} = spawn!(client)
          assert spawned(client, line)["spawn_id"] == spawn_id
          reply(client, vector)
          assert_receive {Channel, ^ref, :released}, 5_000

        %{"type" => "pool"} ->
          test = self()
          spawn_link(fn -> send(test, {:stats, Channel.stats(client.name)}) end)
          {line, ""} = raw_request(client.spawner)
          assert %{"type" => "pool", "pool" => "runner", "id" => id} = Jason.decode!(line)
          reply(client, %{vector | "id" => id})

          assert_receive {:stats,
                          {:ok,
                           %{
                             size: size,
                             free: free,
                             quarantined: quarantined
                           }}},
                         5_000

          assert {size, free, quarantined} ==
                   {vector["size"], vector["free"], vector["quarantined"]}

        other ->
          flunk("no case for the reply #{inspect(other)}")
      end
    end
  end

  test "a reply of the wrong shape is ignored, and the right one still heard", ctx do
    client = start_client!(ctx)
    {ref, line} = spawn!(client)
    %{"spawn_id" => spawn_id} = spawned(client, line)
    exited = reply_vector("exited", &(&1["signal"] == nil))

    log =
      capture_log(fn ->
        reply(client, %{exited | "signal" => "SIGKILL"})
        reply(client, Map.delete(exited, "memory_exceeded"))
        reply(client, %{exited | "v" => 2})
        refute_receive {Channel, ^ref, {:exited, _}}, 200
      end)

    assert log =~ "ambiguous_exit"
    assert log =~ "missing_field"
    assert log =~ "bad_version"

    reply(client, exited)
    code = exited["code"]
    assert exited["spawn_id"] == spawn_id
    assert_receive {Channel, ^ref, {:exited, {:status, ^code}}}, 5_000
  end

  test "the relay's stdout, stderr and control frames are carried", ctx do
    client = start_client!(ctx)
    {ref, line} = spawn!(client)
    spawned(client, line)
    relay = attach!(client, line)
    assert_receive {Channel, ^ref, :attached}, 5_000

    [control_line, control_end] = @vectors["control_frames"]
    stdout = frame_vector("frames", 1)
    stderr_end = frame_vector("frames", 2)

    :ok =
      :gen_tcp.send(relay, [
        encoded(stdout),
        encoded(stderr_end),
        encoded(control_line),
        encoded(control_end)
      ])

    stdout_payload = payload(stdout)
    control_payload = payload(control_line)
    assert_receive {Channel, ^ref, {:log, ^stdout_payload}}, 5_000
    assert_receive {Channel, ^ref, {:control, ^control_payload}}, 5_000
    assert_receive {Channel, ^ref, :control_closed}, 5_000
    :gen_tcp.close(relay)
  end

  test "a frame on stdin or the attach stream, oversized or on no stream, is a relay fault",
       ctx do
    refused =
      [frame_vector("frames", 0), frame_vector("frames", 3)]
      |> Enum.map(&encoded/1)
      |> Kernel.++([<<1, KeeperProtocol.max_frame_bytes() + 1::32>>, <<5, 0::32>>])

    for bytes <- refused do
      client = start_client!(ctx)
      {ref, line} = spawn!(client)
      spawned(client, line)
      relay = attach!(client, line)
      assert_receive {Channel, ^ref, :attached}, 5_000

      :ok = :gen_tcp.send(relay, bytes)

      assert_receive {Channel, ^ref, {:error, :relay_protocol}}, 5_000
      assert_receive {Channel, ^ref, :control_closed}, 5_000
      assert {:error, :closed} = :gen_tcp.recv(relay, 0, 5_000)
    end
  end

  test "an attach frame of the wrong shape is closed, its spawn never attached", ctx do
    client = start_client!(ctx)
    {ref, line} = spawn!(client)
    spawned(client, line)
    %{"attach" => %{"path" => path, "token" => token}} = Jason.decode!(line)

    for bytes <- [<<1, 64::32>> <> token, <<3, 64::32>> <> String.upcase(token)] do
      {:ok, relay} = :gen_tcp.connect({:local, path}, 0, [:binary, active: false])
      :ok = :gen_tcp.send(relay, bytes)
      assert {:error, :closed} = :gen_tcp.recv(relay, 0, 5_000)
    end

    refute_received {Channel, ^ref, :attached}

    # The token is still the spawn's: its relay attaches.
    relay = attach!(client, line)
    assert_receive {Channel, ^ref, :attached}, 5_000
    :gen_tcp.close(relay)
  end
end
