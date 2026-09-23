# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.SpawnKeeperTest do
  @moduledoc """
  The `cyfr-spawn` client against a scripted keeper on a socket the test
  holds the keeper's end of: a runner's handle asks for a spawn in the
  `runner` pool with a control channel and the runner's explicit
  environment; the relay attaches with its token and carries the control
  channel as stream 4, a line split across frames either way; the
  keeper's `exited` and `released` reach the handle; a release carries
  its grace; the pool's stats are asked and answered; and the channel's
  loss reaches every handle and ends the client.
  """

  use ExUnit.Case, async: true

  alias Cyfr.RunnerControl
  alias Opus.Keeper.Spawn
  alias Opus.RunnerProcess

  @stream_stdout 1
  @stream_attach 3
  @stream_control 4
  @max_payload 65_536

  @spec_env %{"OPUS_ROLE" => "runner", "OPUS_RUNNER_ID" => "runner_1", "OPUS_CONTROL_FD" => "3"}

  # The keeper's vectors, the one file the keeper and every client of its
  # wire read. Read as this module compiles, so a checkout without the file
  # fails here, naming it, rather than running without the vectors.
  @vectors Path.expand("../../../../tests/fixtures/spawn_protocol.json", __DIR__)
           |> File.read!()
           |> Jason.decode!()

  setup do
    unique = System.unique_integer([:positive])
    path = Path.join(System.tmp_dir!(), "opus_spawn_#{unique}.sock")
    dir = Path.join(System.tmp_dir!(), "opus_attach_#{unique}")
    File.rm(path)
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)

    {:ok, listener} = :socket.open(:local, :stream)
    :ok = :socket.bind(listener, %{family: :local, path: path})
    :ok = :socket.listen(listener)
    {:ok, keeper_end} = :socket.open(:local, :stream)
    :ok = :socket.connect(keeper_end, %{family: :local, path: path})
    {:ok, spawner} = :socket.accept(listener)

    name = :"spawn_keeper_#{unique}"

    start_supervised!(
      Supervisor.child_spec({Spawn, channel: keeper_end, attach_dir: dir, name: name},
        restart: :temporary
      )
    )

    on_exit(fn ->
      :socket.close(spawner)
      :socket.close(listener)
      File.rm(path)
      File.rm_rf(dir)
    end)

    {:ok, spawner: spawner, name: name, dir: dir}
  end

  defp start_handle!(name, id \\ "runner_1") do
    spec = %{runner: id, argv: ["/app/bin/opus", "start"], env: @spec_env, server: name}
    start_supervised!({RunnerProcess, id: id, keeper: Spawn, spec: spec, owner: self()})
  end

  # The next line the client sent the keeper.
  defp request(spawner, buffer \\ "") do
    case :binary.split(buffer, "\n") do
      [line, _rest] ->
        Jason.decode!(line)

      [partial] ->
        {:ok, data} = :socket.recv(spawner, 0, 5_000)
        request(spawner, partial <> data)
    end
  end

  defp reply(spawner, message), do: :ok = :socket.send(spawner, [Jason.encode!(message), ?\n])

  defp attach!(dir, token) do
    {:ok, relay} =
      :gen_tcp.connect({:local, Path.join(dir, "attach.sock")}, 0, [:binary, active: false])

    :ok = :gen_tcp.send(relay, frame(@stream_attach, token))
    relay
  end

  defp frame(stream, payload), do: [<<stream, byte_size(payload)::32>>, payload]

  # The frames the relay receives, until `bytes` of control payload are in.
  defp control_frames(relay, bytes, acc \\ []) do
    if IO.iodata_length(acc) >= bytes do
      acc
    else
      {:ok, <<@stream_control, length::32>>} = :gen_tcp.recv(relay, 5, 5_000)
      assert length <= @max_payload
      {:ok, payload} = :gen_tcp.recv(relay, length, 5_000)
      control_frames(relay, bytes, acc ++ [payload])
    end
  end

  test "a handle spawns a runner with a control channel and its explicit environment, in the runner pool",
       %{spawner: spawner, name: name, dir: dir} do
    handle = start_handle!(name)

    assert %{
             "v" => 1,
             "type" => "spawn",
             "id" => id,
             "pool" => "runner",
             "control" => true,
             "argv" => ["/app/bin/opus", "start"],
             "env" => @spec_env,
             "attach" => %{"path" => attach_path, "token" => token}
           } = request(spawner)

    assert attach_path == Path.join(dir, "attach.sock")
    assert String.match?(token, ~r/\A[0-9a-f]{64}\z/)

    spawn_id = String.duplicate("ab", 16)
    reply(spawner, %{v: 1, type: "spawned", id: id, spawn_id: spawn_id, uid: 30_101, pid: 4242})

    # The assign is held until the relay attaches, then flushed as frames.
    input = :binary.copy("x", 150_000)
    keys = %{attempt: attempt(), call: :binary.copy(<<1>>, 32), seal: :binary.copy(<<2>>, 32)}

    assert :ok =
             RunnerProcess.send_message(handle, %{
               type: :assign,
               assignment: "token",
               input: input,
               keys: keys
             })

    refute_received {RunnerProcess, ^handle, :ready}

    relay = attach!(dir, token)
    assert_receive {RunnerProcess, ^handle, :ready}, 5_000

    expected =
      IO.iodata_to_binary(
        RunnerControl.encode(%{type: :assign, assignment: "token", input: input, keys: keys})
      )

    payloads = control_frames(relay, byte_size(expected))
    assert length(payloads) > 2
    assert Enum.all?(payloads, &(byte_size(&1) <= @max_payload))
    assert IO.iodata_to_binary(payloads) == expected
    assert RunnerProcess.info(handle) == %{id: "runner_1", os_pid: 4242}

    # A line the runner writes, split across frames, and its log output.
    line =
      IO.iodata_to_binary(
        RunnerControl.encode(%{type: :complete, execution_id: "exec_1", clean: true})
      )

    {head, tail} = String.split_at(line, 10)

    :ok =
      :gen_tcp.send(relay, [
        frame(@stream_control, head),
        frame(@stream_stdout, "runner says hi\n")
      ])

    refute_receive {RunnerProcess, ^handle, {:message, _}}, 100
    :ok = :gen_tcp.send(relay, frame(@stream_control, tail))

    assert_receive {RunnerProcess, ^handle,
                    {:message, %{type: :complete, execution_id: "exec_1", clean: true}}},
                   5_000

    # The runner's end closes, its process ends, its uid is retired.
    :ok = :gen_tcp.send(relay, frame(@stream_control, ""))
    assert_receive {RunnerProcess, ^handle, :closed}, 5_000
    reply(spawner, %{v: 1, type: "exited", spawn_id: spawn_id, code: 0, signal: nil})
    assert_receive {RunnerProcess, ^handle, {:exited, {:status, 0}}}, 5_000
    reply(spawner, %{v: 1, type: "released", spawn_id: spawn_id})
    assert_receive {RunnerProcess, ^handle, :released}, 5_000
    :gen_tcp.close(relay)
  end

  test "an assign held for a relay that has not attached shows no key in either status", %{
    spawner: spawner,
    name: name
  } do
    keys = %{
      attempt: attempt(),
      call: :crypto.strong_rand_bytes(32),
      seal: :crypto.strong_rand_bytes(32)
    }

    assign = %{type: :assign, assignment: "token", input: "{}", keys: keys}

    # The handle holds the assign until its channel attaches.
    handle = start_handle!(name)
    %{"id" => id} = request(spawner)
    reply(spawner, %{v: 1, type: "spawned", id: id, spawn_id: String.duplicate("aa", 16), pid: 1})
    assert :ok = RunnerProcess.send_message(handle, assign)
    refute_received {RunnerProcess, ^handle, :ready}

    # The client holds bytes sent before the relay attached.
    spec = %{runner: "runner_2", argv: ["/app/bin/opus", "start"], env: @spec_env, server: name}
    {:ok, channel, []} = Spawn.spawn(spec)
    _ = request(spawner)
    assert :ok = Spawn.send(channel, RunnerControl.encode(assign))

    for process <- [handle, name], key <- [keys.call, keys.seal] do
      status = :erlang.term_to_binary(:sys.get_status(process))
      assert :binary.match(status, key) == :nomatch
      assert :binary.match(status, Base.encode16(key, case: :lower)) == :nomatch
    end
  end

  test "a release carries its grace, and a signal-ended runner is reported so", %{
    spawner: spawner,
    name: name,
    dir: dir
  } do
    handle = start_handle!(name)
    %{"id" => id, "attach" => %{"token" => token}} = request(spawner)
    spawn_id = String.duplicate("cd", 16)
    reply(spawner, %{v: 1, type: "spawned", id: id, spawn_id: spawn_id, uid: 30_102, pid: 4243})
    relay = attach!(dir, token)
    assert_receive {RunnerProcess, ^handle, :ready}, 5_000

    RunnerProcess.release(handle, 750)

    assert %{"v" => 1, "type" => "release", "spawn_id" => ^spawn_id, "grace_ms" => 750} =
             request(spawner)

    reply(spawner, %{v: 1, type: "exited", spawn_id: spawn_id, code: nil, signal: "SIGKILL"})
    assert_receive {RunnerProcess, ^handle, {:exited, {:signal, "SIGKILL"}}}, 5_000
    :gen_tcp.close(relay)
    assert_receive {RunnerProcess, ^handle, :closed}, 5_000
  end

  test "a release asked before the keeper answered the spawn follows the spawned reply", %{
    spawner: spawner,
    name: name
  } do
    handle = start_handle!(name)
    %{"id" => id} = request(spawner)
    RunnerProcess.release(handle, 0)
    spawn_id = String.duplicate("ef", 16)
    reply(spawner, %{v: 1, type: "spawned", id: id, spawn_id: spawn_id, uid: 30_103, pid: 4244})
    assert %{"type" => "release", "spawn_id" => ^spawn_id, "grace_ms" => 0} = request(spawner)
  end

  test "a spawn the keeper refuses reaches the handle as a refusal: no process of it ran", %{
    spawner: spawner,
    name: name
  } do
    handle = start_handle!(name)
    %{"id" => id} = request(spawner)
    reply(spawner, %{v: 1, type: "error", id: id, code: "capacity"})
    assert_receive {RunnerProcess, ^handle, {:refused, "capacity"}}, 5_000
  end

  test "the pool's stats are asked of the keeper and answered", %{spawner: spawner, name: name} do
    test = self()
    spawn_link(fn -> send(test, {:stats, Spawn.stats(name)}) end)
    assert %{"v" => 1, "type" => "pool", "id" => id, "pool" => "runner"} = request(spawner)

    reply(spawner, %{v: 1, type: "pool", id: id, pool: "runner", size: 8, free: 7, quarantined: 0})

    assert_receive {:stats, {:ok, %{size: 8, free: 7, quarantined: 0}}}, 5_000
  end

  test "the channel's loss reaches every handle and ends the client", %{
    spawner: spawner,
    name: name
  } do
    handle = start_handle!(name)
    _ = request(spawner)
    client = Process.whereis(name)
    ref = Process.monitor(client)

    :socket.close(spawner)

    assert_receive {RunnerProcess, ^handle, {:error, :channel_lost}}, 5_000
    assert_receive {:DOWN, ^ref, :process, ^client, {:shutdown, :channel_lost}}, 5_000
  end

  test "the client's control frames match the keeper's vectors" do
    %{"control_frames" => [line_frame, end_frame]} = @vectors

    payload = Base.decode16!(line_frame["payload_hex"], case: :lower)
    assert {:ok, %{type: :cancel_child}} = RunnerControl.decode(payload)

    assert IO.iodata_to_binary(Spawn.control_frames(payload)) ==
             Base.decode16!(line_frame["encoded_hex"], case: :lower)

    assert IO.iodata_to_binary(Spawn.end_frame()) ==
             Base.decode16!(end_frame["encoded_hex"], case: :lower)
  end

  # This client asks for the pool's memory bound on every spawn: the report
  # every `exited` carries is understood, and the runner's end reaches its
  # handle as its signal.
  test "the keeper's memory vectors: a runner spawn may carry a bound, and an exit reported at one is understood",
       %{spawner: spawner, name: name, dir: dir} do
    assert %{"memory_bytes" => bound, "control" => true, "argv" => ["/app/bin/opus", "start"]} =
             Enum.find(
               @vectors["valid_requests"],
               &(&1["pool"] == "runner" and &1["memory_bytes"])
             )

    assert is_integer(bound) and bound >= 16_777_216

    assert Enum.all?(
             @vectors["replies"],
             &(&1["type"] != "exited" or is_boolean(&1["memory_exceeded"]))
           )

    exited = Enum.find(@vectors["replies"], &(&1["type"] == "exited" and &1["memory_exceeded"]))
    assert %{"code" => nil, "signal" => "SIGKILL", "spawn_id" => spawn_id} = exited

    handle = start_handle!(name)
    %{"id" => id, "attach" => %{"token" => token}} = sent = request(spawner)
    assert {:ok, sent["memory_bytes"]} == Opus.Settings.runner_memory_bytes([])
    reply(spawner, %{v: 1, type: "spawned", id: id, spawn_id: spawn_id, uid: 30_103, pid: 4244})
    relay = attach!(dir, token)
    assert_receive {RunnerProcess, ^handle, :ready}, 5_000

    reply(spawner, exited)
    assert_receive {RunnerProcess, ^handle, {:exited, {:signal, "SIGKILL"}}}, 5_000
    :gen_tcp.close(relay)
    assert_receive {RunnerProcess, ^handle, :closed}, 5_000
  end

  test "the client refuses to run without an inherited channel, and the direct keeper with one" do
    assert :ok = Spawn.available(%{"CYFR_SPAWN_CHANNEL" => "socket:[3]"}, [])
    assert {:error, _} = Spawn.available(%{}, [])
    assert :ok = Spawn.available(%{}, channel: :a_test_socket)
    assert :ok = Opus.Keeper.Direct.available(%{}, [])
    assert {:error, _} = Opus.Keeper.Direct.available(%{"CYFR_SPAWN_CHANNEL" => "socket:[3]"}, [])
    assert_raise ArgumentError, ~r/cannot run here/, fn -> Opus.Keeper.check!(Spawn, []) end
  end

  defp attempt do
    %{
      athanor_id: "ath_1",
      execution_id: "exec_1",
      attempt: "att_1",
      fence: 1,
      generation: 1,
      service: "wrk_local"
    }
  end
end
