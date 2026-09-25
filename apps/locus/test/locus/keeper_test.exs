# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.KeeperTest do
  @moduledoc """
  The client side of cyfr-keeper's protocol. Against a fake spawner
  (`Locus.Test.FakeKeeper`): a run delivers stdin, answers stdout, the log
  line by line and the exit, and returns only after the spawn is reported
  released; every spawn asks for the builder's memory bound, and there is
  no asking for none; the deadline, a stdout bound, a cancel and the
  caller's death release the spawn with no grace; a relay connection that
  arrives after the release report still delivers its output; a refused
  spawn and a lost channel answer at once; a spawn ended at its bound is
  the wire's `memory` refusal and a bound that cannot be enforced its
  `unavailable`, naming the option the deployment lacks. The shared
  vectors are `Locus.KeeperVectorsTest`'s. Whether a real spawn is
  isolated is the builder image tests' to prove.
  """

  use ExUnit.Case, async: false

  alias Locus.Keeper
  alias Locus.Test.FakeKeeper

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

  describe "against the fake spawner" do
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

    test "a spawner that cannot enforce the bound runs nothing: unavailable, naming the option",
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
end
