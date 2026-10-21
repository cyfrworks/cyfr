# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.KeeperChannelTest do
  @moduledoc """
  The runtime's adapter (`Locus.Runtime.Keeper.Channel`) over the node's
  one client of `cyfr-locus` (`Locus.Keeper`), against a scripted keeper
  on a socket the test holds the keeper's end of: a runner's handle asks
  for a spawn in the `runner` pool with a control channel and the
  runner's explicit environment; the relay attaches with its token, is
  sent the zero-length frame that opens the relay stream (5), and carries
  the control channel as stream 4, a line split across frames either way;
  an assign binds the runner's relay to its attempt before it is written;
  the keeper's `exited` and `released` reach the handle; a release carries
  its grace, and a second asks for nothing more; the pool's stats are
  asked and answered; the channel's loss reaches every handle and ends
  the client; and the adapter runs only where the channel was inherited,
  the direct launcher only where it was not.
  """

  use ExUnit.Case, async: true

  alias Prima.{KeeperProtocol, RunnerControl}
  alias Locus.Runtime.Keeper.Channel
  alias Locus.Runtime.RunnerProcess
  alias Locus.Runtime.Test.ScriptedHost

  @stream_stdout 1
  @stream_attach 3
  @stream_control 4
  @max_payload 65_536

  @spec_env %{
    "RUNTIME_ROLE" => "runner",
    "RUNTIME_RUNNER_ID" => "runner_1",
    "RUNTIME_CONTROL_FD" => "3"
  }

  # The keeper's vectors, the one file the keeper and every client of its
  # wire read. Read as this module compiles, so a checkout without the file
  # fails here, naming it, rather than running without the vectors.
  @vectors Path.expand("../../../../../tests/fixtures/keeper_protocol.json", __DIR__)
           |> File.read!()
           |> Jason.decode!()

  setup do
    unique = System.unique_integer([:positive])
    path = Path.join(System.tmp_dir!(), "runtime_spawn_#{unique}.sock")
    dir = Path.join(System.tmp_dir!(), "runtime_attach_#{unique}")
    File.rm(path)
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)

    {:ok, listener} = :socket.open(:local, :stream)
    :ok = :socket.bind(listener, %{family: :local, path: path})
    :ok = :socket.listen(listener)
    {:ok, client_end} = :socket.open(:local, :stream)
    :ok = :socket.connect(client_end, %{family: :local, path: path})
    {:ok, keeper} = :socket.accept(listener)

    # The node's client of the keeper on the test's channel, and the
    # runtime's adapter spawning through it.
    client = __MODULE__.Client
    name = __MODULE__.Adapter

    start_supervised!(
      Supervisor.child_spec(
        {Locus.Keeper, channel: client_end, attach_dir: dir, name: client},
        id: client,
        restart: :temporary
      )
    )

    start_supervised!(
      Supervisor.child_spec({Channel, client: client, name: name}, id: name, restart: :temporary)
    )

    on_exit(fn ->
      :socket.close(keeper)
      :socket.close(listener)
      File.rm(path)
      File.rm_rf(dir)
    end)

    {:ok, keeper: keeper, name: name, client: client, dir: dir}
  end

  defp start_handle!(name, id \\ "runner_1") do
    spec = %{runner: id, argv: ["/app/bin/locus", "start"], env: @spec_env, server: name}
    start_supervised!({RunnerProcess, id: id, keeper: Channel, spec: spec, owner: self()})
  end

  # The next line the client sent the keeper.
  defp request(keeper, buffer \\ "") do
    case :binary.split(buffer, "\n") do
      [line, _rest] ->
        Jason.decode!(line)

      [partial] ->
        {:ok, data} = :socket.recv(keeper, 0, 5_000)
        request(keeper, partial <> data)
    end
  end

  defp reply(keeper, message), do: :ok = :socket.send(keeper, [Jason.encode!(message), ?\n])

  defp attach!(dir, token) do
    {:ok, relay} =
      :gen_tcp.connect({:local, Path.join(dir, "attach.sock")}, 0, [:binary, active: false])

    :ok = :gen_tcp.send(relay, frame(@stream_attach, token))
    relay
  end

  defp frame(stream, payload), do: [<<stream, byte_size(payload)::32>>, payload]

  # The zero-length frame opening the relay stream, which the client sends
  # once the runner attached, before anything else it holds.
  defp opened!(relay), do: assert({:ok, <<5, 0::32>>} = :gen_tcp.recv(relay, 5, 5_000))

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
       %{keeper: keeper, name: name, dir: dir} do
    handle = start_handle!(name)
    {:ok, bound} = Locus.Runtime.Settings.runner_memory_bytes([])

    # The whole request but its own id and attach target: a field dropped
    # or added, the isolation among them, fails here.
    assert %{"id" => id, "attach" => %{"path" => attach_path, "token" => token}} =
             spawned = request(keeper)

    assert Map.drop(spawned, ["id", "attach"]) == %{
             "v" => 1,
             "type" => "spawn",
             "pool" => "runner",
             "control" => true,
             "isolation" => "netns",
             "memory_bytes" => bound,
             "argv" => ["/app/bin/locus", "start"],
             "env" => @spec_env
           }

    assert Map.keys(spawned["attach"]) == ["path", "token"]
    assert attach_path == Path.join(dir, "attach.sock")
    assert String.match?(token, ~r/\A[0-9a-f]{64}\z/)

    spawn_id = String.duplicate("ab", 16)
    reply(keeper, %{v: 1, type: "spawned", id: id, spawn_id: spawn_id, uid: 30_101, pid: 4242})

    # The assign is held until the relay attaches, then flushed as frames,
    # its attempt bound on the runner's relay first.
    input = :binary.copy("x", 150_000)
    attempt = ScriptedHost.attempt!(ScriptedHost.start!())

    assert :ok =
             RunnerProcess.assign(
               handle,
               attempt.assignment,
               input,
               attempt.keys,
               "http://127.0.0.1:9"
             )

    refute_received {RunnerProcess, ^handle, :ready}

    relay = attach!(dir, token)
    assert_receive {RunnerProcess, ^handle, :ready}, 5_000
    opened!(relay)

    expected =
      IO.iodata_to_binary(
        RunnerControl.encode(%{
          type: :assign,
          assignment: attempt.assignment,
          input: input,
          keys: attempt.keys
        })
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

    reply(keeper, %{
      v: 1,
      type: "exited",
      spawn_id: spawn_id,
      code: 0,
      signal: nil,
      memory_exceeded: false
    })

    assert_receive {RunnerProcess, ^handle, {:exited, {:status, 0}}}, 5_000
    reply(keeper, %{v: 1, type: "released", spawn_id: spawn_id})
    assert_receive {RunnerProcess, ^handle, :released}, 5_000
    :gen_tcp.close(relay)
  end

  test "an assign held for a relay that has not attached shows no key in any status", %{
    keeper: keeper,
    name: name,
    client: client
  } do
    attempt = ScriptedHost.attempt!(ScriptedHost.start!())
    keys = attempt.keys
    assign = %{type: :assign, assignment: attempt.assignment, input: "{}", keys: keys}

    # The handle holds the assign until its channel attaches.
    handle = start_handle!(name)
    %{"id" => id} = request(keeper)

    reply(keeper, %{
      v: 1,
      type: "spawned",
      id: id,
      spawn_id: String.duplicate("aa", 16),
      uid: 1,
      pid: 1
    })

    assert :ok =
             RunnerProcess.assign(handle, assign.assignment, "{}", keys, "http://127.0.0.1:9")

    refute_received {RunnerProcess, ^handle, :ready}

    # The client holds bytes sent before the relay attached.
    spec = %{runner: "runner_2", argv: ["/app/bin/locus", "start"], env: @spec_env, server: name}
    {:ok, channel, []} = Channel.spawn(spec)
    _ = request(keeper)
    assert :ok = Channel.send(channel, RunnerControl.encode(assign))

    for process <- [handle, name, client], key <- [keys.call, keys.seal] do
      status = :erlang.term_to_binary(:sys.get_status(process))
      assert :binary.match(status, key) == :nomatch
      assert :binary.match(status, Base.encode16(key, case: :lower)) == :nomatch
    end
  end

  test "a release carries its grace, and a signal-ended runner is reported so", %{
    keeper: keeper,
    name: name,
    dir: dir
  } do
    handle = start_handle!(name)
    %{"id" => id, "attach" => %{"token" => token}} = request(keeper)
    spawn_id = String.duplicate("cd", 16)
    reply(keeper, %{v: 1, type: "spawned", id: id, spawn_id: spawn_id, uid: 30_102, pid: 4243})
    relay = attach!(dir, token)
    assert_receive {RunnerProcess, ^handle, :ready}, 5_000

    RunnerProcess.release(handle, 750)

    assert %{"v" => 1, "type" => "release", "spawn_id" => ^spawn_id, "grace_ms" => 750} =
             request(keeper)

    reply(keeper, %{
      v: 1,
      type: "exited",
      spawn_id: spawn_id,
      code: nil,
      signal: "SIGKILL",
      memory_exceeded: false
    })

    assert_receive {RunnerProcess, ^handle, {:exited, {:signal, "SIGKILL"}}}, 5_000
    :gen_tcp.close(relay)
    assert_receive {RunnerProcess, ^handle, :closed}, 5_000
  end

  test "a release is written once, and a runner whose owner is gone is followed until it is retired",
       %{keeper: keeper, name: name, client: client} do
    test = self()

    owner =
      spawn(fn ->
        spec = %{
          runner: "runner_2",
          argv: ["/app/bin/locus", "start"],
          env: @spec_env,
          server: name
        }

        {:ok, channel, []} = Channel.spawn(spec)
        send(test, {:channel, channel})
        Process.sleep(:infinity)
      end)

    assert_receive {:channel, channel}, 5_000
    %{"id" => id} = request(keeper)
    spawn_id = String.duplicate("12", 16)
    reply(keeper, %{v: 1, type: "spawned", id: id, spawn_id: spawn_id, uid: 30_104, pid: 4245})
    :ok = Channel.release(channel, 500)
    assert %{"type" => "release", "spawn_id" => ^spawn_id, "grace_ms" => 500} = request(keeper)

    # A second release, and the owner's death, ask nothing more of the
    # keeper, which is retiring the uid already.
    :ok = Channel.release(channel, 0)
    Process.exit(owner, :kill)
    assert {:error, :timeout} = :socket.recv(keeper, 0, 200)
    assert map_size(:sys.get_state(client).requests) == 1

    # Its retirement reported, the runner is forgotten.
    reply(keeper, %{v: 1, type: "released", spawn_id: spawn_id})

    Prima.Test.Wait.wait_until(
      fn -> :sys.get_state(client).requests == %{} end,
      5_000,
      "the retired runner to be forgotten"
    )
  end

  test "a release asked before the keeper answered the spawn follows the spawned reply", %{
    keeper: keeper,
    name: name
  } do
    handle = start_handle!(name)
    %{"id" => id} = request(keeper)
    RunnerProcess.release(handle, 0)
    spawn_id = String.duplicate("ef", 16)
    reply(keeper, %{v: 1, type: "spawned", id: id, spawn_id: spawn_id, uid: 30_103, pid: 4244})
    assert %{"type" => "release", "spawn_id" => ^spawn_id, "grace_ms" => 0} = request(keeper)
  end

  test "a spawn the keeper refuses reaches the handle as a refusal: no process of it ran", %{
    keeper: keeper,
    name: name
  } do
    handle = start_handle!(name)
    %{"id" => id} = request(keeper)
    reply(keeper, %{v: 1, type: "error", id: id, code: "capacity"})
    assert_receive {RunnerProcess, ^handle, {:refused, "capacity"}}, 5_000
  end

  test "the channel's loss reaches every handle and ends the client", %{
    keeper: keeper,
    name: name,
    client: client
  } do
    handle = start_handle!(name)
    _ = request(keeper)
    client = Process.whereis(client)
    ref = Process.monitor(client)

    :socket.close(keeper)

    assert_receive {RunnerProcess, ^handle, {:error, :channel_lost}}, 5_000
    assert_receive {:DOWN, ^ref, :process, ^client, {:shutdown, :channel_lost}}, 5_000
  end

  test "the client's control frames match the keeper's vectors" do
    %{"control_frames" => [line_frame, end_frame]} = @vectors

    payload = Base.decode16!(line_frame["payload_hex"], case: :lower)
    assert {:ok, %{type: :cancel_child}} = RunnerControl.decode(payload)

    assert IO.iodata_to_binary(KeeperProtocol.frames(:control, payload)) ==
             Base.decode16!(line_frame["encoded_hex"], case: :lower)

    assert IO.iodata_to_binary(KeeperProtocol.end_frame(:control)) ==
             Base.decode16!(end_frame["encoded_hex"], case: :lower)
  end

  # This client asks for the pool's memory bound on every spawn: the report
  # every `exited` carries is understood, and the runner's end reaches its
  # handle as its signal.
  test "the keeper's memory vectors: a runner spawn may carry a bound, and an exit reported at one is understood",
       %{keeper: keeper, name: name, dir: dir} do
    assert %{"memory_bytes" => bound, "control" => true, "argv" => ["/app/bin/locus", "start"]} =
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
    %{"id" => id, "attach" => %{"token" => token}} = sent = request(keeper)
    assert {:ok, sent["memory_bytes"]} == Locus.Runtime.Settings.runner_memory_bytes([])
    reply(keeper, %{v: 1, type: "spawned", id: id, spawn_id: spawn_id, uid: 30_103, pid: 4244})
    relay = attach!(dir, token)
    assert_receive {RunnerProcess, ^handle, :ready}, 5_000

    reply(keeper, exited)
    assert_receive {RunnerProcess, ^handle, {:exited, {:signal, "SIGKILL"}}}, 5_000
    :gen_tcp.close(relay)
    assert_receive {RunnerProcess, ^handle, :closed}, 5_000
  end

  test "the adapter runs only where the channel was inherited, and the direct launcher only where it was not" do
    assert :ok = Channel.available(true, [])
    assert {:error, reason} = Channel.available(false, [])
    assert reason =~ "KEEPER_CHANNEL is unset, or fd 3 is not the socket it names"
    assert :ok = Locus.DirectLauncher.Runner.available(false, [])
    assert {:error, _} = Locus.DirectLauncher.Runner.available(true, [])

    # This VM inherited no channel: the real check refuses the adapter.
    assert_raise ArgumentError, ~r/cannot run here/, fn ->
      Locus.Runtime.Keeper.check!(Channel, [])
    end

    # The refusal names the one process that can start the service with
    # its channel.
    error = assert_raise ArgumentError, fn -> Locus.Runtime.Keeper.check!(Channel, [], false) end
    assert Exception.message(error) =~ "no keeper channel was inherited"
    assert Exception.message(error) =~ "fd 3"
    assert Exception.message(error) =~ "only through cyfr-locus"
    assert :ok = Locus.Runtime.Keeper.check!(Channel, [], true)
  end
end
