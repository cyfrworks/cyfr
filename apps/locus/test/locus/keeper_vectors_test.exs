# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.KeeperVectorsTest do
  @moduledoc """
  `Locus.Keeper`, the one client of cyfr-locus, against the keeper's
  shared vectors (`tests/fixtures/keeper_protocol.json`, which cyfr-locus
  reproduces), the test process holding the keeper's end of the channel,
  replying with the vectors' own lines and dialling as a spawn's relay
  with the vectors' frames.

  Every spawn names the vectors' place, made before it with their `place`
  request, byte for byte, and answered with their `placed`, the bound its
  spawn will have; a place the keeper refuses is its caller's refusal,
  one refused for room with what held the pool; and a `give_way` reaches
  the owner of the place it names. An assign is the vectors'
  request naming its place under an id of its own, answered with their
  `assigned` or the keeper's refusal, and one the keeper leaves unanswered
  is answered so at its caller's instant and forgotten, its late answer
  reaching no one. A measure is the vectors'
  request naming its place, answered with the reading, whose the place is
  and its age; a reply settles only the measure it names, never a later
  caller's or one that stopped waiting, and the release of the place's
  spawn settles none.

  A build's run: the spawn this client writes is the vectors' build
  spawn, which names no bound, byte for byte but for its own id and attach target; every
  reply category the vectors hold is understood as they say, an
  unsolicited `pool` reply ignored; a reply of the wrong shape is ignored;
  every stream a relay never sends a run (stdin, the attach stream past
  the handshake, the control stream of a spawn that asked for none and the
  relay stream (5), which a run never opens), an oversized frame and one
  on no stream end the run as a relay fault, and a long-lived spawn's
  control or relay frame releases it; and an attach frame of the wrong
  shape is closed.

  A runner's spawn, with a control channel: it is the vectors' runner
  spawn with a control channel, which names no bound, byte for byte but for its
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
    {"placed", nil},
    {"assigned", nil},
    {"error", "bad_request"},
    {"spawned", nil},
    {"error", "capacity"},
    {"error", "memory_unavailable"},
    {"error", "no_memory"},
    {"error", "hosts_unresolved"},
    {"error", "guard_unavailable"},
    {"error", "unknown_spawn"},
    {"error", :made},
    {"exited", :status},
    {"exited", :signal},
    {"exited", :cap},
    {"exited", :machine},
    {"exited", :either},
    {"error", "unmeasured"},
    {"measured", nil},
    {"released", nil},
    {"pool", nil},
    {"give_way", nil},
    {"reported", nil}
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

  # An instant a test's assign waits until for an answer that comes at once.
  defp soon, do: System.monotonic_time(:millisecond) + 5_000

  # A run of `command`, answered with the log lines it produced.
  defp run(name, command \\ %{argv: ["/bin/sh", "-c", "true"], env: %{}}) do
    lines = Agent.start_link(fn -> [] end) |> elem(1)

    result =
      Keeper.run(name, Map.put(command, :stdin, ""),
        place: "pl-1",
        deadline: System.monotonic_time(:millisecond) + 10_000,
        max_stdout_bytes: 1_000_000,
        on_stdout: {[], fn piece, taken -> {:ok, [taken, piece]} end},
        on_output: fn line -> Agent.update(lines, &[line | &1]) end
      )

    {stdout(result), Agent.get(lines, &Enum.reverse/1)}
  end

  # A run's stdout as the fold above took it, whole.
  defp stdout({:ok, %{exit: exit, taken: taken}}),
    do: {:ok, %{exit: exit, stdout: IO.iodata_to_binary(taken)}}

  defp stdout(result), do: result

  # The vectors' place `pl-1`, which their spawns name, made for this
  # process before each spawn: the request is theirs, byte for byte, and
  # answered with their `placed`.
  defp place!(peer, name) do
    vector =
      Enum.find(@vectors["valid_requests"], &(&1["type"] == "place" and &1["id"] == "pl-1"))

    whose = %{kind: vector["kind"], athanor: vector["athanor"], subject: vector["subject"]}
    owner = self()
    task = Task.async(fn -> Keeper.place(name, vector["id"], whose, owner) end)
    assert next_line(peer) == Jason.encode!(vector) <> "\n"
    placed = reply(@vectors, "placed")
    send_reply(peer, placed)
    assert Task.await(task, 5_000) == {:ok, placed["memory_bytes"]}
  end

  test "every reply category the vectors hold is one this module hears" do
    categories =
      @vectors["replies"]
      |> Enum.map(fn
        %{"type" => "error", "id" => _id, "spawn_id" => _spawn_id} -> {"error", :made}
        %{"type" => "error", "code" => code} -> {"error", code}
        %{"type" => "exited", "memory" => "cap"} -> {"exited", :cap}
        %{"type" => "exited", "memory" => "machine"} -> {"exited", :machine}
        %{"type" => "exited", "memory" => "either"} -> {"exited", :either}
        %{"type" => "exited", "signal" => nil} -> {"exited", :status}
        %{"type" => "exited"} -> {"exited", :signal}
        %{"type" => type} -> {type, nil}
      end)
      |> Enum.uniq()
      |> Enum.sort()

    assert categories == Enum.sort(@reply_categories)
  end

  test "the spawn is the vectors' build spawn, which names no bound, byte for byte", %{
    peer: peer,
    name: name
  } do
    vector =
      Enum.find(
        @vectors["valid_requests"],
        &(&1["type"] == "spawn" and &1["pool"] == "build" and not Map.has_key?(&1, "rlimits"))
      ) || flunk("no build spawn without limits among the vectors")

    refute Map.has_key?(vector, "control")
    place!(peer, name)
    task = Task.async(fn -> run(name, %{argv: vector["argv"], env: vector["env"]}) end)
    line = next_line(peer)
    sent = Jason.decode!(line)

    assert line ==
             Jason.encode!(%{vector | "id" => sent["id"], "attach" => sent["attach"]}) <> "\n"

    send_reply(peer, %{v: 9, type: "error", id: sent["id"], code: "capacity"})
    assert {{:error, :capacity}, []} = Task.await(task, 10_000)
  end

  test "the spawned, exited and released replies and the relay's frames complete a run", %{
    v: v,
    peer: peer,
    name: name,
    client: client
  } do
    place!(peer, name)
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
    place!(peer, name)
    task = Task.async(fn -> run(name) end)
    request = next_request(peer)
    send_reply(peer, v |> reply("spawned") |> Map.put("id", request["id"]))
    conn = attach(v, :sys.get_state(client).attach_path, request["attach"]["token"])
    :ok = :gen_tcp.close(conn)

    exited = reply(v, "exited", &(&1["signal"] != nil and &1["memory"] == nil))
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
             &(&1["type"] != "exited" or &1["memory"] in [nil, "cap", "machine", "either"])
           )

    place!(peer, name)
    task = Task.async(fn -> run(name) end)
    request = next_request(peer)
    refute Map.has_key?(request, "memory_bytes") or Map.has_key?(request, "cpu_quota")
    send_reply(peer, v |> reply("spawned") |> Map.put("id", request["id"]))
    conn = attach(v, :sys.get_state(client).attach_path, request["attach"]["token"])
    :ok = :gen_tcp.close(conn)

    exited = reply(v, "exited", &(&1["memory"] == "cap"))
    assert exited["code"] == nil and exited["signal"] == "SIGKILL"
    send_reply(peer, exited)
    send_reply(peer, reply(v, "released"))

    assert {{:error, {:memory, limit}}, []} = Task.await(task, 10_000)
    assert limit == Prima.LocusPool.build_cap_bytes()
  end

  test "the refusal of a bound that cannot be enforced answers the run as the wire's unavailable",
       %{v: v, peer: peer, name: name} do
    place!(peer, name)
    task = Task.async(fn -> run(name) end)
    request = next_request(peer)

    refusal =
      v |> reply("error", &(&1["code"] == "memory_unavailable")) |> Map.put("id", request["id"])

    send_reply(peer, refusal)

    assert {{:error, {:unavailable, sentence}}, []} = Task.await(task, 10_000)
    assert sentence =~ "writable-cgroups=true"
  end

  test "the capacity refusal answers the run as capacity", %{v: v, peer: peer, name: name} do
    place!(peer, name)
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
    place!(peer, name)
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
    place!(peer, name)
    task = Task.async(fn -> run(name) end)
    request = next_request(peer)
    send_reply(peer, v |> reply("spawned") |> Map.put("id", request["id"]))
    conn = attach(v, :sys.get_state(client).attach_path, request["attach"]["token"])
    :ok = :gen_tcp.close(conn)

    exited = reply(v, "exited", &(&1["signal"] == nil))

    log =
      capture_log(fn ->
        send_reply(peer, %{exited | "signal" => "SIGKILL"})
        send_reply(peer, Map.delete(exited, "memory"))
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
      place!(peer, name)
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
      place!(peer, name)

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
                 place: "pl-1",
                 pool: "backends"
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

  test "a measure is the vectors' request naming its place, its reply the reading with whose the place is and its age, and no reading is never a zero",
       %{v: v, peer: peer, name: name} do
    vector = Enum.find(v["valid_requests"], &(&1["type"] == "measure"))

    for {answer, read} <- [
          {reply(v, "measured", &(&1["kind"] == "program")),
           {:ok,
            %{
              kind: "program",
              athanor: "ath_01a09fee-2c3d-7e4f-8a5b-6c7d8e9f0a1b",
              subject: "mcp_01a09fee-2c3d-7e4f-8a5b-6c7d8e9f0a1c",
              bytes: 268_435_456,
              lesser: false,
              age_ms: 412
            }}},
          # A place of no athanor or subject is read as having none.
          {reply(v, "measured", &(&1["kind"] == "warm")),
           {:ok,
            %{
              kind: "warm",
              athanor: nil,
              subject: nil,
              bytes: 201_326_592,
              lesser: true,
              age_ms: 0
            }}},
          # An athanor of any id the other Locus wires take.
          {reply(v, "measured", &(&1["athanor"] == "family@example")),
           {:ok,
            %{
              kind: "build",
              athanor: "family@example",
              subject: nil,
              bytes: 1_048_576,
              lesser: false,
              age_ms: 3
            }}},
          {reply(v, "error", &(&1["code"] == "unmeasured")), {:error, {:refused, "unmeasured"}}}
        ] do
      task = Task.async(fn -> Keeper.measure(name, vector["place"]) end)
      asked = next_request(peer)
      assert asked == %{vector | "id" => asked["id"]}
      send_reply(peer, answering(asked, answer))
      assert Task.await(task, 5_000) == read
    end
  end

  test "a report is the vectors' request after its rev, answered with the role's report under its own id",
       %{v: v, peer: peer, name: name} do
    for vector <- Enum.filter(v["valid_requests"], &(&1["type"] == "report")),
        answer <- Enum.filter(v["replies"], &(&1["type"] == "reported")) do
      task = Task.async(fn -> Keeper.report(name, vector["after"]) end)
      asked = next_request(peer)
      assert asked == %{vector | "id" => asked["id"]}
      send_reply(peer, answering(asked, answer))

      assert {:ok, report} = Task.await(task, 5_000)
      assert {:ok, report} == Prima.LocusPool.read_report(answer["report"])
    end

    # A refusal is its caller's, and a reply naming another id settles nothing.
    task = Task.async(fn -> Keeper.report(name, 0) end)
    asked = next_request(peer)
    send_reply(peer, %{answering(asked, reply(v, "reported")) | "id" => "report-0"})
    assert Task.yield(task, 200) == nil
    send_reply(peer, %{"v" => 9, "type" => "error", "id" => asked["id"], "code" => "bad_request"})
    assert Task.await(task, 5_000) == {:error, {:refused, "bad_request"}}
  end

  test "a reply settles only the measurement it answers, however late or out of order it comes",
       %{v: v, peer: peer, name: name} do
    reading = reply(v, "measured", &(&1["kind"] == "program"))

    read =
      %{kind: "program", athanor: reading["athanor"], subject: reading["subject"]}
      |> Map.merge(%{lesser: false, age_ms: reading["age_ms"]})

    # The first caller stops waiting before its reading is in, and lives on.
    test = self()

    waiter =
      spawn_link(fn ->
        {:timeout, _call} = catch_exit(GenServer.call(name, {:measure, "pl-1"}, 100))
        send(test, :stopped_waiting)

        receive do
          :report -> send(test, {:mailbox, Process.info(self(), :messages)})
        end
      end)

    late = next_request(peer)
    assert_receive :stopped_waiting, 5_000

    second = Task.async(fn -> Keeper.measure(name, "pl-1") end)
    asked = next_request(peer)
    send_reply(peer, %{answering(late, reading) | "bytes" => 4_096})
    send_reply(peer, %{answering(asked, reading) | "bytes" => 8_192})
    assert Task.await(second, 5_000) == {:ok, Map.put(read, :bytes, 8_192)}

    # The late reply reached no one: neither the second caller nor the
    # first, which stopped waiting for it.
    send(waiter, :report)
    assert_receive {:mailbox, {:messages, []}}, 5_000

    # Two waiting at once, answered in the other order.
    third = Task.async(fn -> Keeper.measure(name, "pl-1") end)
    third_asked = next_request(peer)
    fourth = Task.async(fn -> Keeper.measure(name, "pl-1") end)
    fourth_asked = next_request(peer)
    send_reply(peer, %{answering(fourth_asked, reading) | "bytes" => 16_384})
    send_reply(peer, %{answering(third_asked, reading) | "bytes" => 12_288})

    assert {Task.await(third, 5_000), Task.await(fourth, 5_000)} ==
             {{:ok, Map.put(read, :bytes, 12_288)}, {:ok, Map.put(read, :bytes, 16_384)}}
  end

  test "an assign is the vectors' request naming its place under an id of its own, answered once applied or refused",
       %{v: v, peer: peer, name: name} do
    vector = Enum.find(v["valid_requests"], &(&1["type"] == "assign" and &1["kind"] == "run"))
    whose = %{kind: vector["kind"], athanor: vector["athanor"]}

    for {answer, read} <- [
          {reply(v, "assigned"), :ok},
          {reply(v, "error", &(&1["code"] == "bad_request")), {:error, {:refused, "bad_request"}}}
        ] do
      task = Task.async(fn -> Keeper.assign(name, vector["place"], whose, soon()) end)
      asked = next_request(peer)
      assert asked == %{vector | "id" => asked["id"]}
      send_reply(peer, answering(asked, answer))
      assert Task.await(task, 5_000) == read
    end
  end

  test "an assign its keeper does not answer by the end of its wait is answered so and forgotten, and its late answer is ignored",
       %{v: v, peer: peer, name: name} do
    until = System.monotonic_time(:millisecond) + 300
    task = Task.async(fn -> Keeper.assign(name, "pl-1", %{kind: "run"}, until) end)
    assert %{"type" => "assign", "place" => "pl-1"} = asked = next_request(peer)
    assert Task.await(task, 10_000) == {:error, {:launcher_unavailable, :timeout}}
    assert :sys.get_state(name).assigns == %{}

    send_reply(peer, answering(asked, reply(v, "assigned")))
    assert :sys.get_state(name).assigns == %{}
  end

  test "an assign waiting when the channel is lost is answered so", %{peer: peer, name: name} do
    log =
      capture_log(fn ->
        task = Task.async(fn -> Keeper.assign(name, "pl-1", %{kind: "run"}, soon()) end)
        assert %{"type" => "assign", "place" => "pl-1"} = next_request(peer)
        :ok = :socket.close(peer)
        assert Task.await(task, 5_000) == {:error, {:launcher_unavailable, :channel_lost}}
      end)

    assert log =~ "the keeper channel closed"
  end

  test "a measure is settled by its own reply alone: the release of the place's spawn settles none",
       %{v: v, peer: peer, name: name} do
    %{ref: ref} = long_lived!(v, peer, name)
    task = Task.async(fn -> Keeper.measure(name, "pl-1") end)
    asked = next_request(peer)

    send_reply(peer, reply(v, "released"))
    assert_receive {Keeper, ^ref, :released}, 5_000
    assert Task.yield(task, 200) == nil

    send_reply(peer, answering(asked, reply(v, "error", &(&1["code"] == "unmeasured"))))
    assert Task.await(task, 5_000) == {:error, {:refused, "unmeasured"}}
  end

  test "a measured of no bytes is refused as no reading, and settles no measurement",
       %{v: v, peer: peer, name: name} do
    reading = reply(v, "measured")

    log =
      capture_log(fn ->
        task = Task.async(fn -> Keeper.measure(name, "pl-1") end)
        asked = next_request(peer)
        send_reply(peer, %{answering(asked, reading) | "bytes" => 0})
        send_reply(peer, answering(asked, reply(v, "error", &(&1["code"] == "unmeasured"))))
        assert Task.await(task, 5_000) == {:error, {:refused, "unmeasured"}}
      end)

    assert log =~ "invalid_field"
  end

  # A long-lived spawn the vectors' `spawned` answered, its owner this test.
  defp long_lived!(v, peer, name) do
    place!(peer, name)

    keeper =
      Task.async(fn ->
        request = next_request(peer)
        send_reply(peer, v |> reply("spawned") |> Map.put("id", request["id"]))
      end)

    assert {:ok, handle} =
             Keeper.spawn(name, %{
               argv: ["/bin/true"],
               env: %{},
               place: "pl-1",
               pool: "backends"
             })

    Task.await(keeper, 10_000)
    handle
  end

  # The vectors' reply as the keeper answers `request` with it: named as the
  # request is named.
  defp answering(request, reply),
    do: Map.merge(reply, Map.take(request, Map.keys(reply) -- ~w(v type)))

  # ————— a spawn with a control channel —————

  @runner_spawn Enum.find(
                  @vectors["valid_requests"],
                  &(&1["type"] == "spawn" and &1["pool"] == "runner" and &1["control"] == true)
                )

  # Asks for a runner as the runtime's adapter does; the test process owns
  # the spawn and hears its events.
  defp spawn_runner!(peer, name, argv \\ ["/app/bin/locus", "start"]) do
    place!(peer, name)

    assert {:ok, %{spawn_id: nil, uid: nil, pid: nil} = handle} =
             Keeper.spawn(name, %{
               argv: argv,
               env: %{"RUNTIME_ROLE" => "runner"},
               place: "pl-1",
               pool: "runner",
               control: true
             })

    handle
  end

  # A runner spawned with the vectors' `spawned` reply, its spawn id
  # `spawn_id` where named, and its request.
  defp spawned_runner!(v, peer, name, spawn_id \\ nil) do
    %{ref: ref} = handle = spawn_runner!(peer, name)
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

  test "a runner's spawn is the vectors' runner spawn with a control channel and no bound, byte for byte",
       %{peer: peer, name: name} do
    assert %{"control" => true} = @runner_spawn
    refute Map.has_key?(@runner_spawn, "memory_bytes") or Map.has_key?(@runner_spawn, "cpu_quota")
    refute Map.has_key?(@runner_spawn, "isolation")

    place!(peer, name)

    # A runner is answered as soon as it is asked for, before it is staged.
    assert {:ok, %{spawn_id: nil, uid: nil, pid: nil}} =
             Keeper.spawn(name, %{
               argv: @runner_spawn["argv"],
               env: @runner_spawn["env"],
               place: @runner_spawn["place"],
               pool: @runner_spawn["pool"],
               control: true
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
        # A place's answer reaches the process that asked for it, and no
        # runner's owner: `placed` is `place!/2`'s, and a refusal its code.
        %{"type" => "placed"} ->
          place!(peer, name)

        # A place refused for room reaches its caller with what held the
        # pool, as the protocol reads it.
        %{"type" => "error", "id" => place, "code" => "no_memory", "held" => held} ->
          task = Task.async(fn -> Keeper.place(name, place, %{kind: "build"}, self()) end)
          assert %{"type" => "place", "id" => ^place} = next_request(peer)
          send_reply(peer, vector)

          mine =
            for holding <- held["mine"],
                do: %{kind: holding["kind"], subject: holding["subject"], bytes: holding["bytes"]}

          assert Task.await(task, 5_000) ==
                   {:error,
                    {:no_memory,
                     %{
                       need: held["need"],
                       free: held["free"],
                       mine: mine,
                       others_bytes: held["others_bytes"]
                     }}}

        # The keeper's ask to give way reaches the owner of the place it
        # names, here one no spawn has named yet, as the runtime's
        # `:give_way`.
        %{"type" => "give_way", "place" => place} ->
          owner = self()
          task = Task.async(fn -> Keeper.place(name, place, %{kind: "warm"}, owner) end)
          assert %{"type" => "place", "id" => ^place} = next_request(peer)
          send_reply(peer, %{reply(v, "placed") | "id" => place})
          assert {:ok, _bytes} = Task.await(task, 5_000)
          send_reply(peer, vector)
          assert_receive {Keeper, {:place, ^place}, {:give_way, ^place} = event}, 5_000
          assert Locus.Runtime.Keeper.event(event) == :give_way

        %{"type" => "error", "id" => "pl-1", "code" => code} ->
          task = Task.async(fn -> Keeper.place(name, "pl-1", %{kind: "warm"}, self()) end)
          assert %{"type" => "place", "id" => "pl-1"} = next_request(peer)
          send_reply(peer, vector)
          assert Task.await(task, 5_000) == {:error, {:refused, code}}

        %{"type" => "spawned", "spawn_id" => spawn_id, "uid" => uid, "pid" => pid} ->
          %{ref: ref} = spawn_runner!(peer, name)
          send_reply(peer, %{vector | "id" => next_request(peer)["id"]})
          assert_receive {Keeper, ^ref, {:spawned, ^spawn_id, ^uid, ^pid} = event}, 5_000
          assert Locus.Runtime.Keeper.event(event) == {:spawned, pid}

        # An assign's answer reaches the process that asked for it, and no
        # runner's owner.
        %{"type" => "assigned"} ->
          task = Task.async(fn -> Keeper.assign(name, "pl-1", %{kind: "run"}, soon()) end)
          assert %{"type" => "assign", "place" => "pl-1"} = asked = next_request(peer)
          send_reply(peer, answering(asked, vector))
          assert Task.await(task, 5_000) == :ok

        # A runner is not measured, nor reported: its owner hears nothing
        # of a reading or a report.
        %{"type" => type} when type in ["measured", "reported"] ->
          {%{ref: ref}, _request, spawned} = spawned_runner!(v, peer, name)
          send_reply(peer, vector)
          send_reply(peer, %{reply(v, "released") | "spawn_id" => spawned["spawn_id"]})
          assert_receive {Keeper, ^ref, event}, 5_000
          assert event == :released

        # A spawn refused after the keeper made it: its owner hears the
        # refusal at once, its release to follow, and that release only at
        # the keeper's word.
        %{"type" => "error", "id" => _id, "spawn_id" => spawn_id, "code" => code} ->
          %{ref: ref} = spawn_runner!(peer, name)
          send_reply(peer, %{vector | "id" => next_request(peer)["id"]})
          assert_receive {Keeper, ^ref, {:refused, ^code, ^spawn_id} = event}, 5_000
          assert Locus.Runtime.Keeper.event(event) == {:refused, code, :release_follows}
          send_reply(peer, %{reply(v, "released") | "spawn_id" => spawn_id})
          assert_receive {Keeper, ^ref, :released}, 5_000

        %{"type" => "error", "id" => _id, "code" => code} ->
          %{ref: ref} = spawn_runner!(peer, name)
          send_reply(peer, %{vector | "id" => next_request(peer)["id"]})
          assert_receive {Keeper, ^ref, {:refused, ^code} = event}, 5_000
          read = if code == "memory_unavailable", do: :memory_unavailable, else: code
          assert Locus.Runtime.Keeper.event(event) == {:refused, read}

        %{"type" => "error", "spawn_id" => spawn_id, "code" => "unknown_spawn"} ->
          {%{ref: ref}, _request, _spawned} = spawned_runner!(v, peer, name, spawn_id)
          send_reply(peer, vector)
          assert_receive {Keeper, ^ref, :released}, 5_000

        %{"type" => "exited", "spawn_id" => spawn_id, "memory" => spelled} ->
          memory =
            Map.fetch!(
              %{nil => nil, "cap" => :cap, "machine" => :machine, "either" => :either},
              spelled
            )

          {%{ref: ref}, _request, _spawned} = spawned_runner!(v, peer, name, spawn_id)
          send_reply(peer, vector)

          how =
            if vector["signal"],
              do: {:signal, vector["signal"]},
              else: {:status, vector["code"]}

          assert_receive {Keeper, ^ref, {:exited, ^how, ^memory} = event}, 5_000
          assert Locus.Runtime.Keeper.event(event) == {:exited, how, memory}

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
        send_reply(peer, Map.delete(exited, "memory"))
        send_reply(peer, %{exited | "v" => 1})
        refute_receive {Keeper, ^ref, {:exited, _how, _memory}}, 200
      end)

    assert log =~ "ambiguous_exit"
    assert log =~ "missing_field"
    assert log =~ "bad_version"

    send_reply(peer, exited)
    code = exited["code"]
    assert_receive {Keeper, ^ref, {:exited, {:status, ^code}, nil}}, 5_000
  end

  test "the relay's stdout, stderr and control frames are carried, held control bytes first",
       %{v: v, peer: peer, name: name, client: client} do
    {%{ref: ref} = handle, request, _spawned} = spawned_runner!(v, peer, name)

    # Control bytes sent before the relay attaches wait for it, are
    # written as frames of the codec's bound before the relay opens, and
    # are answered once written.
    held = :binary.copy("c", KeeperProtocol.max_frame_bytes() + 10)
    sending = Task.async(fn -> Keeper.send_control(handle, held) end)
    assert Task.yield(sending, 100) == nil

    conn = attach(v, :sys.get_state(client).attach_path, request["attach"]["token"])
    assert_receive {Keeper, ^ref, :attached}, 5_000
    held_frames = IO.iodata_to_binary(KeeperProtocol.frames(:control, held))
    assert {:ok, ^held_frames} = :gen_tcp.recv(conn, byte_size(held_frames), 5_000)
    assert Task.await(sending) == :ok
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
    # The owner takes each piece, as a runner's process does, and the
    # client reads the next only then.
    assert_receive {Keeper, ^ref, {:stdout, ^stdout_payload} = event}, 5_000
    :ok = Keeper.taken(handle)
    assert Locus.Runtime.Keeper.event(event) == {:log, stdout_payload}
    assert_receive {Keeper, ^ref, {:control, ^control_payload}}, 5_000
    :ok = Keeper.taken(handle)
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
    :ok = Keeper.taken(handle)

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
