# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.DirectKeeperTest do
  @moduledoc """
  The `Direct` keeper ends a runner's whole process group, the leader and
  everything it started: at once on a release with no grace, after the
  grace for what ignores the term signal, and when the process that
  spawned the runner ends without releasing it. The runner here is a
  shell that starts a child and names it on its standard output, which
  is the channel the keeper hands the spawning process.
  """

  use ExUnit.Case, async: false

  import Opus.Test.Wait

  alias Opus.Keeper.Direct

  setup do
    unless Process.whereis(Direct), do: start_supervised!(Direct)
    :ok
  end

  # A leader that starts a child, names it, and waits on it; with
  # `ignore_term`, both ignore the term signal, which a child inherits.
  defp spawn_family!(opts \\ []) do
    trap = if Keyword.get(opts, :ignore_term, false), do: "trap '' TERM; ", else: ""

    spec = %{
      runner: "runner_direct_#{System.unique_integer([:positive])}",
      argv: ["/bin/sh", "-c", trap <> "sleep 300 & echo $!; wait"],
      env: %{}
    }

    {:ok, channel, [{:spawned, leader}, :attached]} = Direct.spawn(spec)
    {channel, leader, child_pid(channel)}
  end

  defp child_pid(%{port: port} = channel) do
    receive do
      {^port, {:data, _data}} = message ->
        {:events, [{:control, line}], _channel} = Direct.handle_message(channel, message)
        line |> String.trim() |> String.to_integer()
    after
      5_000 -> flunk("the runner never named its child")
    end
  end

  # A process that has exited is gone even while its parent has yet to reap
  # it: a zombie holds no memory and runs nothing.
  defp alive?(os_pid) do
    case System.cmd("ps", ["-o", "stat=", "-p", Integer.to_string(os_pid)],
           stderr_to_stdout: true
         ) do
      {stat, 0} -> not String.starts_with?(String.trim(stat), "Z")
      {_none, _status} -> false
    end
  end

  defp assert_gone(pids) do
    for pid <- pids do
      wait_until(fn -> not alive?(pid) end, 5_000, "process #{pid} of the runner to be gone")
    end
  end

  test "a release with no grace kills the leader and the child it started" do
    {channel, leader, child} = spawn_family!()
    assert alive?(leader) and alive?(child)

    :ok = Direct.release(channel, 0)

    assert_gone([leader, child])
  end

  test "a release with a grace kills what ignored the term signal once the grace is over" do
    {channel, leader, child} = spawn_family!(ignore_term: true)
    assert alive?(leader) and alive?(child)

    :ok = Direct.release(channel, 200)

    assert_gone([leader, child])
  end

  test "a runner whose spawning process ends unreleased is reaped, child and all" do
    test = self()

    owner =
      spawn(fn ->
        send(test, {:family, spawn_family!()})

        receive do
          :exit -> :ok
        end
      end)

    assert_receive {:family, {_channel, leader, child}}, 10_000
    assert alive?(leader) and alive?(child)

    send(owner, :exit)

    assert_gone([leader, child])
  end

  describe "a runner's log relay" do
    # A home as `Direct.spawn/1` lays it out, and the relay reading its
    # fifo as `Direct.spawn/1` starts it, with no runner ever opening the
    # fifo to write: the relay waits in its open, which is where a runner
    # ended before its shell opened the fifo leaves it.
    defp stranded_relay! do
      home =
        Path.join(System.tmp_dir!(), "opus_runner_test_#{System.unique_integer([:positive])}")

      log = Path.join(home, "log")
      File.mkdir_p!(home)
      {_out, 0} = System.cmd("mkfifo", ["-m", "600", log])
      relay = Port.open({:spawn_executable, "/bin/cat"}, [:binary, :stream, :eof, args: [log]])
      {:os_pid, os_pid} = Port.info(relay, :os_pid)
      {home, relay, os_pid}
    end

    test "a relay waiting on a fifo no runner opened ends when the home is removed" do
      {home, relay, os_pid} = stranded_relay!()
      assert alive?(os_pid)

      assert :ok = Direct.remove_home(home)

      assert_receive {^relay, :eof}, 5_000
      Port.close(relay)
      assert_gone([os_pid])
      refute File.exists?(home)
    end

    test "removing a home whose relay has already ended does not wait on its fifo" do
      {home, relay, os_pid} = stranded_relay!()
      Port.close(relay)
      System.cmd("kill", ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)
      assert_gone([os_pid])

      task = Task.async(fn -> Direct.remove_home(home) end)
      assert {:ok, :ok} = Task.yield(task, 5_000)
      refute File.exists?(home)
    end
  end
end
