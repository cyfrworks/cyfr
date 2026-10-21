# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.KeeperVectorsTest do
  @moduledoc """
  `Locus.Keeper`, the one client of cyfr-locus, against the keeper's
  shared vectors (`tests/fixtures/keeper_protocol.json`, which cyfr-locus
  reproduces), the test process holding the keeper's end of the channel,
  replying with the vectors' own lines and dialling as a spawn's relay
  with the vectors' frames.

  A build's run: the spawn this client writes is the vectors' bounded
  build spawn, byte for byte but for its own id and attach target; every
  reply category the vectors hold is understood as they say, an
  unsolicited `pool` reply ignored; a reply of the wrong shape is ignored;
  every stream a relay never sends a run (stdin, the attach stream past
  the handshake, the control stream of a spawn that asked for none and the
  relay stream (5), which a run never opens), an oversized frame and one
  on no stream end the run as a relay fault, and a long-lived spawn's
  control or relay frame releases it; and an attach frame of the wrong
  shape is closed.

  A runner's spawn, with a control channel: it is the vectors' bounded,
  isolated runner spawn with a control channel, byte for byte but for its
  own id and attach target; every reply the vectors hold reaches its owner
  as the event it means, and the runtime's reading of it
  (`Locus.Runtime.Keeper.event/1`); a reply of the wrong shape, a wrong
  version among them, is ignored; the relay's stdout, stderr and control
  frames are carried, control bytes held for a relay not yet attached
  going first; the relay stream (5) is opened with the vectors'
  zero-length frame once the runner attaches, carries relay frames both
  ways and ends with a zero-length frame from either side; a frame on
  stdin or the attach stream, an oversized one or one on no stream closes
  the connection as a relay fault, the release left to the owner; and an
  attach frame of the wrong shape is closed, the token still the spawn's.
  """

  use ExUnit.Case, async: true

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
    {:ok, client} = Keeper.start_link(channel: channel, attach_dir: attach_dir, name: nil)
    Process.unlink(client)
    :ok = :socket.setopt(channel, {:otp, :controlling_process}, client)
    Process.put(:peer_buffer, "")

    on_exit(fn ->
      Process.exit(client, :kill)
      File.rm_rf!(attach_dir)
    end)

    {:ok, v: @vectors, peer: peer, name: client, client: client}
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

    # Stream 5 is the relay, which this client never opens; stream 6 is no
    # stream of the protocol's.
    faults =
      Enum.map(refused, &encoded/1) ++
        [<<5, 0::32>>, <<1, KeeperProtocol.max_frame_bytes() + 1::32>>, <<6, 0::32>>]

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

  test "a long-lived spawn's relay that sends a control or relay frame is at fault and released",
       %{v: v, peer: peer, name: name, client: client} do
    for bytes <- [encoded(hd(v["control_frames"])), <<5, 0::32>>] do
      # The keeper's side answers the spawn while this process, the
      # spawn's owner, waits for its handle.
      keeper =
        Task.async(fn ->
          request = next_request(peer)
          spawned = v |> reply("spawned") |> Map.put("id", request["id"])
          send_reply(peer, spawned)
          {request, spawned}
        end)

      assert {:ok, %{ref: ref}} =
               Keeper.spawn(name, %{
                 argv: ["/bin/true"],
                 env: %{},
                 pool: "backends",
                 memory_bytes: 268_435_456
               })

      {request, spawned} = Task.await(keeper, 10_000)

      conn = attach(v, :sys.get_state(client).attach_path, request["attach"]["token"])
      assert_receive {Keeper, ^ref, :attached}, 5_000
      :ok = :gen_tcp.send(conn, bytes)

      assert {:error, :closed} = :gen_tcp.recv(conn, 0, 5_000)
      release = next_request(peer)
      assert %{"type" => "release", "grace_ms" => 0} = release
      assert release["spawn_id"] == spawned["spawn_id"]
      send_reply(peer, reply(v, "released"))
      assert_receive {Keeper, ^ref, :released}, 5_000
    end
  end

  # ————— a spawn with a control channel —————

  @runner_spawn Enum.find(
                  @vectors["valid_requests"],
                  &(&1["pool"] == "runner" and &1["control"] == true and &1["memory_bytes"])
                )

  # Asks for a runner as the runtime's adapter does; the test process owns
  # the spawn and hears its events.
  defp spawn_runner!(name, argv \\ ["/app/bin/locus", "start"]) do
    assert {:ok, %{spawn_id: nil, uid: nil, pid: nil} = handle} =
             Keeper.spawn(name, %{
               argv: argv,
               env: %{"RUNTIME_ROLE" => "runner"},
               pool: "runner",
               memory_bytes: @runner_spawn["memory_bytes"],
               control: true,
               isolation: "netns"
             })

    handle
  end

  # A runner spawned with the vectors' `spawned` reply, its spawn id
  # `spawn_id` where named, and its request.
  defp spawned_runner!(v, peer, name, spawn_id \\ nil) do
    %{ref: ref} = handle = spawn_runner!(name)
    request = next_request(peer)
    spawned = v |> reply("spawned") |> Map.put("id", request["id"])
    spawned = if spawn_id, do: %{spawned | "spawn_id" => spawn_id}, else: spawned
    send_reply(peer, spawned)
    expected = spawned["spawn_id"]
    assert_receive {Keeper, ^ref, {:spawned, ^expected, _uid, _pid}}, 5_000
    {handle, request, spawned}
  end

  # The first bytes a runner's relay reads once it attached, after the
  # control bytes held for it: the zero-length frame that opens the relay
  # stream and ends nothing.
  defp opened!(v, conn) do
    [open | _] = v["relay_frames"]
    assert {:ok, bytes} = :gen_tcp.recv(conn, 5, 5_000)
    assert bytes == encoded(open)
  end

  # A fresh client and its peer, for a case that leaves its client's state
  # behind.
  defp fresh_client! do
    {peer, channel} = channel_pair()
    attach_dir = FakeKeeper.short_tmp_dir()
    {:ok, client} = Keeper.start_link(channel: channel, attach_dir: attach_dir, name: nil)
    Process.unlink(client)
    :ok = :socket.setopt(channel, {:otp, :controlling_process}, client)
    Process.put(:peer_buffer, "")

    on_exit(fn ->
      Process.exit(client, :kill)
      File.rm_rf!(attach_dir)
    end)

    {peer, client}
  end

  test "a runner's spawn is the vectors' bounded, isolated runner spawn with a control channel, byte for byte",
       %{peer: peer, name: name} do
    assert %{"control" => true, "memory_bytes" => _bound, "isolation" => "netns"} = @runner_spawn

    # A runner is answered as soon as it is asked for, before it is staged.
    assert {:ok, %{spawn_id: nil, uid: nil, pid: nil}} =
             Keeper.spawn(name, %{
               argv: @runner_spawn["argv"],
               env: @runner_spawn["env"],
               pool: @runner_spawn["pool"],
               memory_bytes: @runner_spawn["memory_bytes"],
               control: true,
               isolation: @runner_spawn["isolation"]
             })

    line = next_line(peer)
    sent = Jason.decode!(line)

    assert line ==
             Jason.encode!(%{@runner_spawn | "id" => sent["id"], "attach" => sent["attach"]}) <>
               "\n"

    assert sent["attach"]["token"] =~ ~r/\A[0-9a-f]{64}\z/
  end

  test "every reply the vectors hold reaches a runner's owner as the event it means, and the runtime's",
       %{v: v} do
    for vector <- v["replies"] do
      {peer, name} = fresh_client!()

      case vector do
        %{"type" => "spawned", "spawn_id" => spawn_id, "uid" => uid, "pid" => pid} ->
          %{ref: ref} = spawn_runner!(name)
          send_reply(peer, %{vector | "id" => next_request(peer)["id"]})
          assert_receive {Keeper, ^ref, {:spawned, ^spawn_id, ^uid, ^pid} = event}, 5_000
          assert Locus.Runtime.Keeper.event(event) == {:spawned, pid}

        %{"type" => "error", "id" => _id, "code" => code} ->
          %{ref: ref} = spawn_runner!(name)
          send_reply(peer, %{vector | "id" => next_request(peer)["id"]})
          assert_receive {Keeper, ^ref, {:refused, ^code} = event}, 5_000
          read = if code == "memory_unavailable", do: :memory_unavailable, else: code
          assert Locus.Runtime.Keeper.event(event) == {:refused, read}

        %{"type" => "error", "spawn_id" => spawn_id, "code" => "unknown_spawn"} ->
          {%{ref: ref}, _request, _spawned} = spawned_runner!(v, peer, name, spawn_id)
          send_reply(peer, vector)
          assert_receive {Keeper, ^ref, :released}, 5_000

        %{"type" => "exited", "spawn_id" => spawn_id, "memory_exceeded" => memory_exceeded} ->
          {%{ref: ref}, _request, _spawned} = spawned_runner!(v, peer, name, spawn_id)
          send_reply(peer, vector)

          how =
            if vector["signal"],
              do: {:signal, vector["signal"]},
              else: {:status, vector["code"]}

          assert_receive {Keeper, ^ref, {:exited, ^how, ^memory_exceeded} = event}, 5_000
          assert Locus.Runtime.Keeper.event(event) == {:exited, how}

        %{"type" => "released", "spawn_id" => spawn_id} ->
          {%{ref: ref}, _request, _spawned} = spawned_runner!(v, peer, name, spawn_id)
          send_reply(peer, vector)
          assert_receive {Keeper, ^ref, :released}, 5_000

        %{"type" => "pool"} ->
          task = Task.async(fn -> Keeper.pool_stats(name, "runner") end)
          assert %{"type" => "pool", "pool" => "runner", "id" => id} = next_request(peer)
          send_reply(peer, %{vector | "id" => id})
          assert {:ok, stats} = Task.await(task, 5_000)

          assert {stats.size, stats.free, stats.quarantined} ==
                   {vector["size"], vector["free"], vector["quarantined"]}

        other ->
          flunk("no case for the reply #{inspect(other)}")
      end
    end
  end

  test "a reply of the wrong shape is ignored by a runner's spawn, and the right one still heard",
       %{v: v, peer: peer, name: name} do
    {%{ref: ref}, _request, spawned} = spawned_runner!(v, peer, name)
    exited = reply(v, "exited", &(&1["signal"] == nil))
    assert exited["spawn_id"] == spawned["spawn_id"]

    log =
      capture_log(fn ->
        send_reply(peer, %{exited | "signal" => "SIGKILL"})
        send_reply(peer, Map.delete(exited, "memory_exceeded"))
        send_reply(peer, %{exited | "v" => 2})
        refute_receive {Keeper, ^ref, {:exited, _how, _memory}}, 200
      end)

    assert log =~ "ambiguous_exit"
    assert log =~ "missing_field"
    assert log =~ "bad_version"

    send_reply(peer, exited)
    code = exited["code"]
    assert_receive {Keeper, ^ref, {:exited, {:status, ^code}, false}}, 5_000
  end

  test "the relay's stdout, stderr and control frames are carried, held control bytes first",
       %{v: v, peer: peer, name: name, client: client} do
    {%{ref: ref} = handle, request, _spawned} = spawned_runner!(v, peer, name)

    # Control bytes sent before the relay attaches wait for it, and are
    # written as frames of the codec's bound before the relay opens.
    held = :binary.copy("c", KeeperProtocol.max_frame_bytes() + 10)
    assert :ok = Keeper.send_control(handle, held)

    conn = attach(v, :sys.get_state(client).attach_path, request["attach"]["token"])
    assert_receive {Keeper, ^ref, :attached}, 5_000
    held_frames = IO.iodata_to_binary(KeeperProtocol.frames(:control, held))
    assert {:ok, ^held_frames} = :gen_tcp.recv(conn, byte_size(held_frames), 5_000)
    opened!(v, conn)

    [control_line, control_end] = v["control_frames"]
    stdout = frame_vector(v, "frames", 1)
    stderr_end = frame_vector(v, "frames", 2)

    :ok =
      :gen_tcp.send(conn, [
        encoded(stdout),
        encoded(stderr_end),
        encoded(control_line),
        encoded(control_end)
      ])

    stdout_payload = payload(stdout)
    control_payload = payload(control_line)
    assert_receive {Keeper, ^ref, {:stdout, ^stdout_payload} = event}, 5_000
    assert Locus.Runtime.Keeper.event(event) == {:log, stdout_payload}
    assert_receive {Keeper, ^ref, {:control, ^control_payload}}, 5_000
    assert_receive {Keeper, ^ref, :control_closed}, 5_000
    :gen_tcp.close(conn)
  end

  test "the relay stream opens once a runner attaches, carries relay frames both ways and ends",
       %{v: v, peer: peer, name: name, client: client} do
    {%{ref: ref} = handle, request, _spawned} = spawned_runner!(v, peer, name)

    # Nothing is written to the relay before it opens.
    assert {:error, :relay_closed} = Keeper.send_relay(handle, "early")
    conn = attach(v, :sys.get_state(client).attach_path, request["attach"]["token"])
    assert_receive {Keeper, ^ref, :attached}, 5_000

    # The client speaks first on the stream, since the keeper sends nothing
    # on it until the client has: the vectors' opening frame.
    opened!(v, conn)

    # What the runner wrote to its fd 4 reaches the owner verbatim.
    [_open, carried, close] = v["relay_frames"]
    :ok = :gen_tcp.send(conn, encoded(carried))
    carried_payload = payload(carried)
    assert_receive {Keeper, ^ref, {:relay, ^carried_payload}}, 5_000

    # What the service writes is framed on stream 5, from any process; no
    # bytes write nothing.
    task = Task.async(fn -> Keeper.send_relay(handle, payload(carried)) end)
    assert :ok = Task.await(task)
    assert :ok = Keeper.send_relay(handle, "")
    assert {:ok, bytes} = :gen_tcp.recv(conn, byte_size(encoded(carried)), 5_000)
    assert bytes == encoded(carried)

    # The keeper's zero-length frame ends the stream: the runner closed its
    # fd 4. The control channel stays open.
    :ok = :gen_tcp.send(conn, encoded(close))
    assert_receive {Keeper, ^ref, :relay_closed}, 5_000
    refute_receive {Keeper, ^ref, :control_closed}, 100
    assert {:error, :relay_closed} = Keeper.send_relay(handle, "more")
    :gen_tcp.close(conn)
  end

  test "the service ends a runner's relay stream with a zero-length frame",
       %{v: v, peer: peer, name: name, client: client} do
    {%{ref: ref} = handle, request, _spawned} = spawned_runner!(v, peer, name)
    conn = attach(v, :sys.get_state(client).attach_path, request["attach"]["token"])
    assert_receive {Keeper, ^ref, :attached}, 5_000
    opened!(v, conn)

    :ok = Keeper.close_relay(handle)
    [_open, _carried, close] = v["relay_frames"]
    assert {:ok, bytes} = :gen_tcp.recv(conn, 5, 5_000)
    assert bytes == encoded(close)
    assert {:error, :relay_closed} = Keeper.send_relay(handle, "more")
    :gen_tcp.close(conn)
  end

  test "a runner's frame on stdin or the attach stream, oversized or on no stream, is a relay fault left to its owner",
       %{v: v} do
    # Stream 6 is no stream of the protocol's; stream 5 is the relay.
    refused =
      [frame_vector(v, "frames", 0), frame_vector(v, "frames", 3)]
      |> Enum.map(&encoded/1)
      |> Kernel.++([<<1, KeeperProtocol.max_frame_bytes() + 1::32>>, <<6, 0::32>>])

    for bytes <- refused do
      {peer, name} = fresh_client!()
      client = name
      {%{ref: ref}, request, _spawned} = spawned_runner!(v, peer, name)
      conn = attach(v, :sys.get_state(client).attach_path, request["attach"]["token"])
      assert_receive {Keeper, ^ref, :attached}, 5_000
      opened!(v, conn)

      :ok = :gen_tcp.send(conn, bytes)

      assert_receive {Keeper, ^ref, :control_closed}, 5_000
      assert_receive {Keeper, ^ref, :relay_closed}, 5_000
      assert_receive {Keeper, ^ref, {:error, :relay_protocol}}, 5_000
      assert {:error, :closed} = :gen_tcp.recv(conn, 0, 5_000)

      # The connection is forgotten, and the release is the owner's.
      assert :sys.get_state(client).conns == %{}
      assert {:error, :timeout} = :socket.recv(peer, 0, 200)
    end
  end

  test "an attach frame of the wrong shape is closed, a runner's token still its own",
       %{v: v, peer: peer, name: name, client: client} do
    {%{ref: ref}, request, _spawned} = spawned_runner!(v, peer, name)
    path = :sys.get_state(client).attach_path
    token = request["attach"]["token"]

    for bytes <- [<<1, 64::32>> <> token, <<3, 64::32>> <> String.upcase(token)] do
      {:ok, conn} = :gen_tcp.connect({:local, path}, 0, [:binary, active: false])
      :ok = :gen_tcp.send(conn, bytes)
      assert {:error, :closed} = :gen_tcp.recv(conn, 0, 5_000)
    end

    refute_received {Keeper, ^ref, :attached}

    # The token is still the spawn's: its relay attaches.
    conn = attach(v, path, token)
    assert_receive {Keeper, ^ref, :attached}, 5_000
    :gen_tcp.close(conn)
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
