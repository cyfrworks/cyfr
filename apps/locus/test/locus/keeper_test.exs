# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.KeeperTest do
  @moduledoc """
  The client side of cyfr-locus's protocol. Against a fake keeper
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
  is sent. Fd 3 is the channel only when it links to the socket
  `KEEPER_CHANNEL` names. No credential leaves the client: a runner's
  held assign, a frame not yet whole and every message carrying a
  payload show no key or environment value in a status or a crash
  report, a crash report names the reason the client stopped by its kind
  alone, and a call to a client that is gone, or a run whose client
  crashed, answers the failure by its kind alone. A runner's relay that
  stops reading is closed once a write to it waits out the 5 s bound, and
  its owner hears its control channel and relay closed. The spawns'
  vectors are `Locus.KeeperVectorsTest`'s. Whether a real spawn is
  isolated is the image tests' to prove.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Locus.Keeper
  alias Locus.Runtime.Test.ScriptedHost
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

      assert {:error, {:keeper_unavailable, {:attach_dir_not_private, ^dir}}} =
               Keeper.start_link(channel: channel, attach_dir: dir, name: :keeper_open_dir)

      File.rm_rf!(dir)
    end

    test "fd 3 is the channel only when it is the socket cyfr-locus names" do
      env = fn value -> fn "KEEPER_CHANNEL" -> value end end
      link = fn target -> fn "/proc/self/fd/3" -> target end end

      assert Keeper.channel_inherited?(env.("socket:[4242]"), link.({:ok, "socket:[4242]"}))
      refute Keeper.channel_inherited?(env.("socket:[4242]"), link.({:ok, "socket:[1]"}))
      refute Keeper.channel_inherited?(env.("socket:[4242]"), link.({:ok, "/dev/null"}))
      refute Keeper.channel_inherited?(env.("socket:[4242]"), link.({:error, :enoent}))
      refute Keeper.channel_inherited?(env.(nil), link.({:ok, "socket:[4242]"}))
      refute Keeper.channel_inherited?(env.(""), link.({:ok, ""}))

      # This VM was started by no keeper: whatever its fd 3 is, the
      # variable names nothing it links to.
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
      assert Keeper.channel_env() == "KEEPER_CHANNEL"
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
      name = :"keeper_plant_#{System.unique_integer([:positive])}"
      {:ok, client} = Keeper.start_link(channel: channel, attach_dir: attach_dir, name: name)
      Process.unlink(client)
      :ok = :socket.setopt(channel, {:otp, :controlling_process}, client)

      on_exit(fn ->
        Process.exit(client, :kill)
        File.rm_rf!(attach_dir)
      end)

      %{peer: peer, name: name, client: client, attach_dir: attach_dir}
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

    test "(a) a runner's held assign, its partial frames and every payload message show no key or environment value" do
      p = plant()
      c = plain_client!()
      adapter = :"keeper_plant_adapter_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Locus.Runtime.Keeper.Channel, client: c.name, memory_bytes: 268_435_456, name: adapter}
      )

      # The runtime's adapter asks for the runner, as a runner's process
      # does, with the planted environment.
      spec = %{
        runner: "runner_plant",
        argv: ["/app/bin/locus", "start"],
        env: p.env,
        server: adapter
      }

      assert {:ok, channel, []} = Locus.Runtime.Keeper.Channel.spawn(spec)
      %{"id" => id, "attach" => %{"token" => token}} = request(c.peer)
      spawn_id = String.duplicate("ab", 16)

      :ok =
        :socket.send(c.peer, [
          Jason.encode!(%{v: 1, type: "spawned", id: id, spawn_id: spawn_id, uid: 1, pid: 1}),
          ?\n
        ])

      assert_receive {Keeper, _ref, {:spawned, ^spawn_id, 1, 1}}, 5_000

      # The assign, sent before the relay attaches, is held.
      assert :ok = Locus.Runtime.Keeper.Channel.send(channel, p.assign)

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
      hex = Base.encode16(p.key, case: :lower)
      :ok = :gen_tcp.send(relay, [<<4, 4_000::32>>, ~s({"keys":{"call":"#{hex}")])

      wait_until(fn ->
        Enum.any?(:sys.get_state(c.client).requests, fn {_ref, entry} -> entry.frames != "" end)
      end)

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
            {:spawn, ["/app/bin/locus", "start"], p.env, 268_435_456},
            {:spawn_handle, ref, ["/app/bin/locus", "start"], p.env,
             %{pool: "runner", memory_bytes: 268_435_456, control: true, isolation: "netns"}}
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
          timeout_ms: 1_000,
          max_stdout_bytes: 1_000
        )

      launched =
        Keeper.spawn(:no_such_keeper_client, %{argv: ["/bin/true"], env: p.env, pool: "runner"})

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

      task =
        Task.async(fn ->
          Keeper.run(c.name, %{argv: ["/bin/true"], env: p.env, stdin: p.assign},
            timeout_ms: 10_000,
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
      assert {:ok, %{ref: ref} = handle} =
               Keeper.spawn(c.name, %{
                 argv: ["/app/bin/locus", "start"],
                 env: %{},
                 pool: "runner",
                 memory_bytes: 268_435_456,
                 control: true,
                 isolation: "netns"
               })

      %{"id" => id, "attach" => %{"token" => token}} = request(c.peer)
      spawn_id = String.duplicate("cd", 16)

      spawned = %{v: 1, type: "spawned", id: id, spawn_id: spawn_id, uid: 1, pid: 1}
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

    # Every event of `ref` until a second passes with none, in order.
    defp heard(ref, acc \\ []) do
      receive do
        {Keeper, ^ref, event} -> heard(ref, [event | acc])
      after
        1_000 -> Enum.reverse(acc)
      end
    end

    defp queued_at_least(pid, n) do
      wait_until(fn -> elem(Process.info(pid, :message_queue_len), 1) >= n end)
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
      {%{ref: ref} = handle, relay} = attached_runner!(c)

      # The service writes to the runner while the runner, having written
      # its last control line, closes its end; the client hears all three
      # only after the write.
      :ok = :sys.suspend(c.client)
      writer = Task.async(fn -> Keeper.send_control(handle, ~s({"type":"cancel_child"}\n)) end)
      queued_at_least(c.client, 1)
      last = ~s({"type":"complete"}\n)
      :ok = :gen_tcp.send(relay, KeeperProtocol.frames(:control, last))
      :ok = :gen_tcp.close(relay)
      queued_at_least(c.client, 3)
      :ok = :sys.resume(c.client)

      assert {:error, _reason} = Task.await(writer)
      assert heard(ref) == [{:control, last}, :control_closed, :relay_closed]
    end

    @tag timeout: 60_000
    test "a runner's control frame received while a write waits out its bound reaches its owner first" do
      c = plain_client!()
      {%{ref: ref} = handle, relay} = attached_runner!(c)
      chunk = :binary.copy("x", KeeperProtocol.max_frame_bytes())

      writer =
        Task.async(fn ->
          Stream.repeatedly(fn -> Keeper.send_control(handle, chunk) end)
          |> Enum.find(&(&1 != :ok))
        end)

      # Once a write waits on the full connection, the runner writes its
      # last line, which the client receives while it waits.
      wait_until(fn -> writing?(Process.whereis(c.name)) end)
      last = ~s({"type":"complete"}\n)
      :ok = :gen_tcp.send(relay, KeeperProtocol.frames(:control, last))

      assert {:error, :timeout} = Task.await(writer, 15_000)
      assert heard(ref) == [{:control, last}, :control_closed, :relay_closed]
      :gen_tcp.close(relay)
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
