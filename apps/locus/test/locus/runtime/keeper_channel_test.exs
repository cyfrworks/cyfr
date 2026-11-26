# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.KeeperChannelTest do
  @moduledoc """
  The runtime's adapter (`Locus.Runtime.Keeper.Channel`) over the node's
  one client of `cyfr-locus` (`Locus.Keeper`), against a scripted keeper
  on a socket the test holds the keeper's end of: a runner's handle
  makes the runner's place, named by its id, then asks for a spawn in
  that place, in the `runner` pool with a control channel and the
  runner's explicit environment; the relay attaches with its token, is
  sent the zero-length frame that opens the relay stream (5), and carries
  the control channel as stream 4, a line split across frames either way;
  an assign makes the runner's place its work's athanor's run, answered by
  the keeper, before it binds the runner's relay to its attempt and is
  written, and a clean completion makes it warm again before the handle's
  owner hears it;
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

  # A runner's handle, which makes the runner's place before its spawn.
  defp start_handle!(keeper, name, id \\ "runner_1") do
    spec = %{runner: id, argv: ["/app/bin/locus", "start"], env: @spec_env, server: name}

    handle =
      start_supervised!(
        {RunnerProcess,
         id: id, keeper: Channel, keeper_opts: [server: name], spec: spec, owner: self()}
      )

    placed!(keeper, id)
    handle
  end

  # The place `id` the client asks for, a runner's at rest, answered as
  # cyfr-locus answers it.
  defp placed!(keeper, id) do
    assert %{"v" => 8, "type" => "place", "id" => ^id, "kind" => "warm"} = request(keeper)
    reply(keeper, %{v: 8, type: "placed", id: id, memory_bytes: 402_653_184})
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

  # The assign of the runner's place the client asks for, `kind` of
  # `athanor`'s under an id of its own, answered as cyfr-locus answers it.
  defp assigned!(keeper, kind, athanor, place \\ "runner_1") do
    assert %{"type" => "assign", "id" => id} = asked = request(keeper)

    assert Map.delete(asked, "id") == %{
             "v" => 8,
             "type" => "assign",
             "place" => place,
             "kind" => kind,
             "athanor" => athanor
           }

    reply(keeper, %{v: 8, type: "assigned", id: id})
  end

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
    handle = start_handle!(keeper, name)

    # The whole request but its own id and attach target: a field dropped
    # or added fails here: no isolation, whose reach is the pool's, and no
    # bound, which the keeper sets by the place's kind.
    assert %{"id" => id, "attach" => %{"path" => attach_path, "token" => token}} =
             spawned = request(keeper)

    assert Map.drop(spawned, ["id", "attach"]) == %{
             "v" => 8,
             "type" => "spawn",
             "place" => "runner_1",
             "pool" => "runner",
             "control" => true,
             "argv" => ["/app/bin/locus", "start"],
             "env" => @spec_env
           }

    assert Map.keys(spawned["attach"]) == ["path", "token"]
    assert attach_path == Path.join(dir, "attach.sock")
    assert String.match?(token, ~r/\A[0-9a-f]{64}\z/)

    spawn_id = String.duplicate("ab", 16)
    reply(keeper, %{v: 8, type: "spawned", id: id, spawn_id: spawn_id, uid: 30_101, pid: 4242})

    # The assign is held until the relay attaches, then flushed as frames,
    # its attempt bound on the runner's relay first, once the keeper has
    # made the runner's place its athanor's run.
    input = :binary.copy("x", 150_000)
    attempt = ScriptedHost.attempt!(ScriptedHost.start!(), athanor_id: "family@example")

    assigning =
      Task.async(fn ->
        RunnerProcess.assign(
          handle,
          attempt.assignment,
          input,
          attempt.keys,
          "http://127.0.0.1:9",
          System.monotonic_time(:millisecond) + 5_000
        )
      end)

    assigned!(keeper, "run", "family@example")
    assert :ok = Task.await(assigning)

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

    # Its place is back at rest, still the athanor's, before its owner
    # hears the completion.
    assigned!(keeper, "warm", "family@example")

    assert_receive {RunnerProcess, ^handle,
                    {:message, %{type: :complete, execution_id: "exec_1", clean: true}}},
                   5_000

    # The runner's end closes, its process ends, its uid is retired.
    :ok = :gen_tcp.send(relay, frame(@stream_control, ""))
    assert_receive {RunnerProcess, ^handle, :closed}, 5_000

    reply(keeper, %{
      v: 8,
      type: "exited",
      spawn_id: spawn_id,
      code: 0,
      signal: nil,
      memory: nil
    })

    # Its end is heard once its connection has carried its last frame.
    :gen_tcp.close(relay)
    assert_receive {RunnerProcess, ^handle, {:exited, {:status, 0}, nil}}, 5_000
    reply(keeper, %{v: 8, type: "released", spawn_id: spawn_id})
    assert_receive {RunnerProcess, ^handle, :released}, 5_000
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
    handle = start_handle!(keeper, name)
    %{"id" => id} = request(keeper)

    reply(keeper, %{
      v: 8,
      type: "spawned",
      id: id,
      spawn_id: String.duplicate("aa", 16),
      uid: 1,
      pid: 1
    })

    assigning =
      Task.async(fn ->
        RunnerProcess.assign(
          handle,
          assign.assignment,
          "{}",
          keys,
          "http://127.0.0.1:9",
          System.monotonic_time(:millisecond) + 5_000
        )
      end)

    assigned!(keeper, "run", "ath_test")
    assert :ok = Task.await(assigning)
    refute_received {RunnerProcess, ^handle, :ready}

    # The client holds bytes sent before the relay attached.
    test = self()
    placing = Task.async(fn -> Locus.Keeper.place(client, "runner_2", %{kind: "warm"}, test) end)
    placed!(keeper, "runner_2")
    assert {:ok, 402_653_184} = Task.await(placing)
    spec = %{runner: "runner_2", argv: ["/app/bin/locus", "start"], env: @spec_env, server: name}
    {:ok, channel, []} = Channel.spawn(spec)
    _ = request(keeper)
    sending = Task.async(fn -> Channel.send(channel, RunnerControl.encode(assign)) end)

    Prima.Test.Wait.wait_until(fn ->
      Enum.any?(:sys.get_state(client).requests, fn {_ref, entry} -> entry.pending != [] end)
    end)

    for process <- [handle, name, client], key <- [keys.call, keys.seal] do
      status = :erlang.term_to_binary(:sys.get_status(process))
      assert :binary.match(status, key) == :nomatch
      assert :binary.match(status, Base.encode16(key, case: :lower)) == :nomatch
    end

    # Unwritten, the send is not answered.
    assert Task.yield(sending, 0) == nil
    Task.shutdown(sending, :brutal_kill)
  end

  test "a release carries its grace, and a signal-ended runner is reported so", %{
    keeper: keeper,
    name: name,
    dir: dir
  } do
    handle = start_handle!(keeper, name)
    %{"id" => id, "attach" => %{"token" => token}} = request(keeper)
    spawn_id = String.duplicate("cd", 16)
    reply(keeper, %{v: 8, type: "spawned", id: id, spawn_id: spawn_id, uid: 30_102, pid: 4243})
    relay = attach!(dir, token)
    assert_receive {RunnerProcess, ^handle, :ready}, 5_000

    RunnerProcess.release(handle, 750)

    assert %{"v" => 8, "type" => "release", "spawn_id" => ^spawn_id, "grace_ms" => 750} =
             request(keeper)

    reply(keeper, %{
      v: 8,
      type: "exited",
      spawn_id: spawn_id,
      code: nil,
      signal: "SIGKILL",
      memory: nil
    })

    # Its end follows its connection's.
    :gen_tcp.close(relay)
    assert_receive {RunnerProcess, ^handle, :closed}, 5_000
    assert_receive {RunnerProcess, ^handle, {:exited, {:signal, "SIGKILL"}, nil}}, 5_000
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

        {:ok, _bytes} = Channel.place("runner_2", %{kind: "warm"}, server: name)
        {:ok, channel, []} = Channel.spawn(spec)
        send(test, {:channel, channel})
        Process.sleep(:infinity)
      end)

    placed!(keeper, "runner_2")
    assert_receive {:channel, channel}, 5_000
    %{"id" => id} = request(keeper)
    spawn_id = String.duplicate("12", 16)
    reply(keeper, %{v: 8, type: "spawned", id: id, spawn_id: spawn_id, uid: 30_104, pid: 4245})
    :ok = Channel.release(channel, 500)
    assert %{"type" => "release", "spawn_id" => ^spawn_id, "grace_ms" => 500} = request(keeper)

    # A second release, and the owner's death, ask nothing more of the
    # keeper, which is retiring the uid already.
    :ok = Channel.release(channel, 0)
    Process.exit(owner, :kill)
    assert {:error, :timeout} = :socket.recv(keeper, 0, 200)
    assert map_size(:sys.get_state(client).requests) == 1

    # Its retirement reported, the runner is forgotten.
    reply(keeper, %{v: 8, type: "released", spawn_id: spawn_id})

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
    handle = start_handle!(keeper, name)
    %{"id" => id} = request(keeper)
    RunnerProcess.release(handle, 0)
    spawn_id = String.duplicate("ef", 16)
    reply(keeper, %{v: 8, type: "spawned", id: id, spawn_id: spawn_id, uid: 30_103, pid: 4244})
    assert %{"type" => "release", "spawn_id" => ^spawn_id, "grace_ms" => 0} = request(keeper)
  end

  test "a spawn the keeper refuses reaches the handle as a refusal: no process of it ran", %{
    keeper: keeper,
    name: name
  } do
    handle = start_handle!(keeper, name)
    %{"id" => id} = request(keeper)
    reply(keeper, %{v: 8, type: "error", id: id, code: "capacity"})
    assert_receive {RunnerProcess, ^handle, {:refused, "capacity"}}, 5_000
  end

  test "the channel's loss reaches every handle and ends the client", %{
    keeper: keeper,
    name: name,
    client: client
  } do
    handle = start_handle!(keeper, name)
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

  # The keeper bounds every runner: the report every `exited` carries is
  # understood, and the runner's end reaches its handle as its signal and
  # the bound that ended it.
  test "the keeper's memory vectors: an exit reported at a runner's bound is understood",
       %{keeper: keeper, name: name, dir: dir} do
    assert Enum.all?(
             @vectors["replies"],
             &(&1["type"] != "exited" or &1["memory"] in [nil, "cap", "machine", "either"])
           )

    exited = Enum.find(@vectors["replies"], &(&1["type"] == "exited" and &1["memory"] == "cap"))
    assert %{"code" => nil, "signal" => "SIGKILL", "spawn_id" => spawn_id} = exited

    handle = start_handle!(keeper, name)
    %{"id" => id, "attach" => %{"token" => token}} = request(keeper)
    reply(keeper, %{v: 8, type: "spawned", id: id, spawn_id: spawn_id, uid: 30_103, pid: 4244})
    relay = attach!(dir, token)
    assert_receive {RunnerProcess, ^handle, :ready}, 5_000

    reply(keeper, exited)
    :gen_tcp.close(relay)
    assert_receive {RunnerProcess, ^handle, :closed}, 5_000
    assert_receive {RunnerProcess, ^handle, {:exited, {:signal, "SIGKILL"}, :cap}}, 5_000
  end

  # The keeper asks of its own accord that an idle runner give way: the ask
  # reaches the runner's handle as `:give_way`, which tells its owner,
  # whether a spawn had named the runner's place yet or not.
  test "the keeper's give_way of a runner's place reaches its handle's owner, before its spawn is named or after",
       %{keeper: keeper, name: name} do
    handle = start_handle!(keeper, name)
    assert_receive {RunnerProcess, ^handle, {:placed, 402_653_184}}, 5_000
    %{"id" => id} = request(keeper)

    reply(keeper, %{
      v: 8,
      type: "spawned",
      id: id,
      spawn_id: String.duplicate("cd", 16),
      uid: 1,
      pid: 1
    })

    reply(keeper, %{v: 8, type: "give_way", place: "runner_1"})
    assert_receive {RunnerProcess, ^handle, :give_way}, 5_000

    channel = %{runner: "runner_1", ref: make_ref()}

    assert Channel.handle_message(
             channel,
             {Locus.Keeper, {:place, "runner_1"}, {:give_way, "runner_1"}}
           ) ==
             {:events, [:give_way], channel}

    assert Channel.handle_message(
             channel,
             {Locus.Keeper, {:place, "runner_2"}, {:give_way, "runner_2"}}
           ) ==
             :unknown
  end

  test "a runner's place refused for room is the keeper's no_memory refusal, keeping what holds the memory" do
    held = %{need: 402_653_184, free: 0, mine: [], others_bytes: 0}

    assert Channel.refusal({:no_memory, held}) ==
             %{
               reason: "no_memory",
               message: "cyfr-locus refused to start a runner (no_memory)",
               held: held
             }
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
