# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.SpawnerTest do
  @moduledoc """
  The client side of cyfr-spawn's protocol, against a fake spawner
  (`Locus.Test.FakeSpawner`): a run delivers stdin, answers stdout, the log
  line by line and the exit, and returns only after the spawn is reported
  released; the deadline, a stdout bound and the caller's death release
  the spawn with no grace; a relay connection that arrives after the
  release report still delivers its output; a refused spawn and a lost
  channel answer at once. Whether a real spawn is isolated is the builder
  image tests' to prove.
  """

  use ExUnit.Case, async: false

  alias Locus.Spawner
  alias Locus.Test.FakeSpawner

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
        timeout_ms: Keyword.get(opts, :timeout_ms, 10_000),
        max_stdout_bytes: Keyword.get(opts, :max_stdout_bytes, 1_000_000),
        on_output: fn line -> Agent.update(lines, &[line | &1]) end
      )

    {result, Agent.get(lines, &Enum.reverse/1)}
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

    assert {:ok, %{exit: {:status, 3}, stdout: stdout, log: log}} = result
    assert String.trim(stdout) == "200000"
    assert lines == ["hello", "partial"]
    assert log == "hello\npartial"

    [spawn] = fake |> FakeSpawner.requests() |> Enum.filter(&(&1["type"] == "spawn"))
    assert spawn["pool"] == "build"
    assert spawn["env"] == %{"GREETING" => "hello"}
    assert spawn["attach"]["token"] =~ ~r/^[0-9a-f]{64}$/
  end

  test "a run past its deadline releases the spawn with no grace", %{name: name, fake: fake} do
    started = System.monotonic_time(:millisecond)
    {result, _lines} = run(name, "sleep 30", timeout_ms: 300)

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
    caller = spawn(fn -> run(name, "sleep 30") end)
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
    task = Task.async(fn -> run(name, "sleep 30") end)
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

  defp wait_until(check, attempts \\ 100) do
    cond do
      check.() -> :ok
      attempts == 0 -> flunk("condition never held")
      true -> Process.sleep(50) && wait_until(check, attempts - 1)
    end
  end
end
