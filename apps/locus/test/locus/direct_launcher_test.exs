# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.DirectLauncherTest do
  @moduledoc """
  The test environment's executor ends what it started on every path: at
  the command's exit, at its deadline and at a cancel it kills the
  command's process group before it answers, and when its caller dies a
  janitor that outlives the caller kills the group and removes the run's
  directory. It gives the command an environment built from nothing, and
  no memory bound. As the test environment's launcher it holds a
  long-lived process for its owner: stdin as it is sent, stdout and
  stderr apart, a signal, a release with a grace, the exit and the
  release, the last; an owner that dies has the process group killed and
  its home removed. As the runtime's keeper (`Locus.DirectLauncher.Runner`)
  it ends a runner's whole process group, the leader and everything it
  started: at once on a release with no grace, after the grace for what
  ignores the term signal, and when the process that spawned the runner
  ends without releasing it. A stderr reader waiting on a fifo no process
  opened ends when its home is removed, and one stranded there, which
  that removal does not wake, is stopped on every path a runner ends by:
  its release, its own exit, its owner's death and the janitor's end.
  """

  use ExUnit.Case, async: true

  import Locus.Test.ProcessFamily
  import Prima.Test.Wait

  alias Locus.DirectLauncher

  defp alive?(os_pid) do
    {_out, status} = System.cmd("kill", ["-0", os_pid], stderr_to_stdout: true, env: no_env())
    status == 0
  end

  defp run(script, opts \\ []) do
    DirectLauncher.run(
      %{
        argv: ["/bin/sh", "-c", script],
        env: Keyword.get(opts, :env, %{}),
        stdin: opts[:stdin] || ""
      },
      timeout_ms: Keyword.get(opts, :timeout_ms, 30_000),
      max_stdout_bytes: Keyword.get(opts, :max_stdout_bytes, 1_000_000),
      on_output: Keyword.get(opts, :on_output, fn _line -> :ok end)
    )
  end

  # A script that starts a child, writes its own pid, the child's and its
  # home to `file`, one a line, and waits for longer than any test.
  defp lingering do
    file = Path.join(System.tmp_dir!(), "locus_dl_#{System.unique_integer([:positive])}.pids")
    on_exit(fn -> File.rm(file) end)
    {~s(sleep 300 & echo $$ > #{file}; echo $! >> #{file}; echo "$HOME" >> #{file}; wait), file}
  end

  defp left_in(file) do
    wait_until(
      fn ->
        match?({:ok, _}, File.read(file)) and
          length(String.split(File.read!(file), "\n", trim: true)) == 3
      end,
      10_000
    )

    [shell, child, home] = String.split(File.read!(file), "\n", trim: true)
    {[shell, child], home}
  end

  test "a run delivers stdin, answers stdout and the exit status, and its log by line" do
    test = self()

    assert {:ok, %{exit: {:status, 3}, stdout: stdout}} =
             run(~s(wc -c | tr -d ' '; echo "$GREETING" >&2; printf partial >&2; exit 3),
               stdin: :binary.copy("x", 200_000),
               env: %{"GREETING" => "hello"},
               on_output: &send(test, {:line, &1})
             )

    assert String.trim(stdout) == "200000"
    assert_received {:line, "hello"}
    assert_received {:line, "partial"}
  end

  test "the command sees the environment it was given and the launcher's own, and nothing of this node's" do
    # A variable of this node's that a child must not see. Its name stays
    # outside the `LOCUS_` family: `Locus.Config` refuses an unknown
    # variable of that family, and its tests read the environment beside
    # this one.
    System.put_env("DL_NODE_SECRET", "of this node's")
    on_exit(fn -> System.delete_env("DL_NODE_SECRET") end)

    assert {:ok, %{exit: {:status, 0}, stdout: env}} = run("env", env: %{"GIVEN" => "yes"})

    names = for line <- String.split(env, "\n", trim: true), do: line |> String.split("=") |> hd()

    assert Enum.sort(names -- ~w(PWD SHLVL _ OLDPWD)) ==
             Enum.sort(~w(COPYFILE_DISABLE GIVEN HOME LOGNAME PATH TMPDIR USER))

    refute env =~ "DL_NODE_SECRET"
  end

  test "its home is its own and is gone when it ends" do
    assert {:ok, %{stdout: home}} = run(~s(touch "$HOME/left-behind"; printf %s "$HOME"))
    assert String.starts_with?(Path.expand(home), Path.expand(System.tmp_dir!()))
    refute File.exists?(home)
    refute home == System.user_home()
  end

  test "stdout past its bound is refused" do
    assert {:error, {:output_too_large, 1_000}} =
             run("head -c 5000 /dev/zero", max_stdout_bytes: 1_000)
  end

  test "a run past its deadline has its process group killed before it answers" do
    {script, file} = lingering()
    started = System.monotonic_time(:millisecond)

    assert {:error, :timeout} = run(script, timeout_ms: 1_000)
    assert System.monotonic_time(:millisecond) - started < 10_000

    {os_pids, home} = left_in(file)
    for os_pid <- os_pids, do: wait_until(fn -> not alive?(os_pid) end, 10_000)
    refute File.exists?(home)
  end

  test "a cancelled run has its process group killed, and answers cancelled" do
    {script, file} = lingering()
    test = self()
    runner = spawn_link(fn -> send(test, {:answer, run(script)}) end)

    {os_pids, home} = left_in(file)
    assert Enum.all?(os_pids, &alive?/1)

    :ok = Locus.Executor.cancel(runner)
    assert_receive {:answer, {:error, :cancelled}}, 10_000

    for os_pid <- os_pids, do: wait_until(fn -> not alive?(os_pid) end, 10_000)
    refute File.exists?(home)
  end

  test "a cancel that arrived before the run ends it as it starts" do
    Locus.Executor.cancel(self())
    assert {:error, :cancelled} = run("sleep 300")
  end

  test "a caller that dies has its run ended by the janitor: the group killed, the directory removed" do
    {script, file} = lingering()
    caller = spawn(fn -> run(script) end)

    {os_pids, home} = left_in(file)
    assert Enum.all?(os_pids, &alive?/1)
    assert File.dir?(home)

    Process.exit(caller, :kill)

    for os_pid <- os_pids, do: wait_until(fn -> not alive?(os_pid) end, 10_000)
    wait_until(fn -> not File.exists?(home) end, 10_000)
    wait_until(fn -> not File.exists?(Path.dirname(home)) end, 10_000)
  end

  describe "a long-lived process" do
    test "is this launcher's under the test environment, by the executor's rule" do
      refute Locus.Keeper.running?()
      assert Locus.Executor.executor() == {:ok, DirectLauncher}
    end

    defp spawn_live(script, env \\ %{}) do
      DirectLauncher.spawn([], %{
        argv: ["/bin/sh", "-c", script],
        env: env,
        pool: "backends",
        memory_bytes: 268_435_456
      })
    end

    defp events_until_released(%{ref: ref}, acc \\ []) do
      receive do
        {DirectLauncher, ^ref, :released} -> Enum.reverse([:released | acc])
        {DirectLauncher, ^ref, event} -> events_until_released(%{ref: ref}, [event | acc])
      after
        10_000 -> flunk("no release; heard #{length(acc)} events")
      end
    end

    defp stream(events, name),
      do: for({^name, bytes} <- events, into: "", do: bytes)

    test "its owner hears it attached, its stdout and stderr apart, its exit and its release" do
      assert {:ok, handle} =
               spawn_live(~s(echo out; echo "$GREETING" >&2; printf '%s' "$HOME" >&2; exit 4), %{
                 "GREETING" => "hello"
               })

      assert is_integer(handle.pid) and handle.uid == nil
      events = events_until_released(handle)

      assert hd(events) == :attached
      assert stream(events, :stdout) == "out\n"
      assert "hello\n" <> home = stream(events, :stderr)
      assert Enum.take(events, -2) == [{:exited, 4, nil}, :released]
      refute File.exists?(home)

      assert {:ok, %{size: 1, free: 1, quarantined: 0}} =
               DirectLauncher.pool_stats([], "backends")
    end

    test "send writes its stdin" do
      assert {:ok, handle} = spawn_live("exec head -c 150000")
      data = :binary.copy("0123456789", 15_000)
      assert :ok = DirectLauncher.send(handle, data)

      events = events_until_released(handle)
      assert stream(events, :stdout) == data
      assert {:exited, 0, nil} in events
      assert {:error, :unknown_spawn} = DirectLauncher.send(handle, "late")
    end

    test "signal signals its process group" do
      assert {:ok, handle} = spawn_live("echo ready; exec sleep 30")
      assert_receive {DirectLauncher, _ref, {:stdout, "ready\n"}}, 10_000

      assert {:error, :unencodable} = DirectLauncher.signal(handle, "SIGSTOP")
      assert :ok = DirectLauncher.signal(handle, "SIGTERM")

      assert Enum.take(events_until_released(handle), -2) == [
               {:exited, nil, "SIGTERM"},
               :released
             ]
    end

    test "release with a grace lets it end on its own, and kills it once the grace passes" do
      script = ~s(trap 'echo term; exit 0' TERM; echo ready; while :; do sleep 0.1; done)
      assert {:ok, handle} = spawn_live(script)
      assert_receive {DirectLauncher, _ref, {:stdout, "ready\n"}}, 10_000

      :ok = DirectLauncher.release([], handle, 2_000)
      events = events_until_released(handle)
      assert stream(events, :stdout) =~ "term\n"
      assert {:exited, 0, nil} in events

      assert {:ok, stubborn} =
               spawn_live(~s(trap '' TERM; echo ready; while :; do sleep 0.1; done))

      assert_receive {DirectLauncher, _ref, {:stdout, "ready\n"}}, 10_000
      started = System.monotonic_time(:millisecond)
      :ok = DirectLauncher.release([], stubborn, 300)

      assert Enum.take(events_until_released(stubborn), -2) == [
               {:exited, nil, "SIGKILL"},
               :released
             ]

      assert System.monotonic_time(:millisecond) - started >= 300
    end

    test "an owner that dies has its process group killed and its home removed" do
      {script, file} = lingering()
      test = self()

      owner =
        spawn(fn ->
          {:ok, handle} = spawn_live(script)
          send(test, {:spawned, handle})
          Process.sleep(:infinity)
        end)

      assert_receive {:spawned, _handle}, 10_000
      {os_pids, home} = left_in(file)
      assert Enum.all?(os_pids, &alive?/1)

      Process.exit(owner, :kill)

      for os_pid <- os_pids, do: wait_until(fn -> not alive?(os_pid) end, 10_000)
      wait_until(fn -> not File.exists?(home) end, 10_000)
    end
  end

  describe "a runner, through the runtime's face" do
    alias Locus.DirectLauncher.Runner

    setup do
      unless Process.whereis(Runner), do: start_supervised!(Runner)
      :ok
    end

    test "a release with no grace kills the leader and the child it started" do
      {channel, leader, child} = spawn_family!()
      assert running?(leader) and running?(child)

      :ok = Runner.release(channel, 0)

      assert_gone([leader, child])
      assert {:exited, {:signal, "SIGKILL"}} = event_until(channel, &match?({:exited, _}, &1))
      assert :released = event_until(channel, &(&1 == :released))
    end

    test "a release with a grace kills what ignored the term signal once the grace is over" do
      {channel, leader, child} = spawn_family!(ignore_term: true)
      assert running?(leader) and running?(child)

      :ok = Runner.release(channel, 200)

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
      assert running?(leader) and running?(child)

      send(owner, :exit)

      assert_gone([leader, child])
    end

    # A runner whose stderr reader is stranded (`strand_reader: true`): the
    # reader waits in its open of a fifo the runner never opens and the
    # home's removal does not wake, so only the reader's stop ends it. The
    # runner's handle and the reader's OS pid.
    defp stranded!(script, janitor \\ Runner) do
      spec = %{argv: ["/bin/sh", "-c", script], env: %{}, pool: "runner", control: true}
      {:ok, handle} = DirectLauncher.spawn([janitor: janitor, strand_reader: true], spec)
      reader = "/bin/cat " <> Path.join(handle.home, "stderr")
      wait_until(fn -> readers(reader) != [] end, 10_000)
      [os_pid] = readers(reader)

      # On Linux the kernel says where it waits: for a writer of the fifo.
      if File.exists?("/proc/#{os_pid}/wchan") do
        wait_until(
          fn -> File.read("/proc/#{os_pid}/wchan") == {:ok, "wait_for_partner"} end,
          10_000
        )
      end

      {handle, os_pid}
    end

    # The OS pids of the processes whose command line is `command`.
    defp readers(command) do
      {listing, 0} = System.cmd("ps", ["-eo", "pid=,args="], env: no_env())

      for line <- String.split(listing, "\n"),
          [pid, args] <- [String.split(String.trim(line), " ", parts: 2)],
          args == command,
          do: String.to_integer(pid)
    end

    defp released!(%{ref: ref}) do
      receive do
        {DirectLauncher, ^ref, :released} -> :ok
        {DirectLauncher, ^ref, _event} -> released!(%{ref: ref})
      after
        10_000 -> flunk("the runner was never released")
      end
    end

    defp reader_gone!(os_pid) do
      wait_until(fn -> not running?(os_pid) end, 10_000)
      refute running?(os_pid), "the stderr reader #{os_pid} outlived its runner"
    end

    test "a stranded stderr reader of a released runner is stopped" do
      {handle, reader} = stranded!("exec sleep 30")

      :ok = DirectLauncher.release([], handle, 0)

      released!(handle)
      reader_gone!(reader)
    end

    test "a stranded stderr reader of a runner that ended on its own is stopped" do
      {handle, reader} = stranded!("sleep 0.5; exit 0")

      released!(handle)
      reader_gone!(reader)
    end

    test "a stranded stderr reader of a runner whose owner died is stopped" do
      test = self()

      owner =
        spawn(fn ->
          send(test, {:stranded, stranded!("exec sleep 30")})
          Process.sleep(:infinity)
        end)

      assert_receive {:stranded, {handle, reader}}, 10_000
      Process.exit(owner, :kill)

      wait_until(fn -> not File.exists?(handle.home) end, 10_000)
      reader_gone!(reader)
    end

    test "the janitor forgets a reader that has ended, so its pid is never signalled" do
      {:ok, janitor} = GenServer.start(Runner, [])
      on_exit(fn -> if Process.alive?(janitor), do: GenServer.stop(janitor) end)

      # The runner closes its stderr and runs on: its reader reads the end
      # and exits while the runner is still held.
      spec = %{
        argv: ["/bin/sh", "-c", "exec 2>&-; sleep 30"],
        env: %{},
        pool: "runner",
        control: true
      }

      {:ok, handle} = DirectLauncher.spawn([janitor: janitor], spec)
      child = handle.server

      wait_until(fn -> :sys.get_state(janitor).runners[child].reader_os_pid == nil end, 10_000)
      assert running?(handle.pid)

      :ok = DirectLauncher.release([], handle, 0)
      released!(handle)
    end

    test "a stranded stderr reader is stopped by the janitor's end" do
      {:ok, janitor} = GenServer.start(Runner, [])
      {handle, reader} = stranded!("exec sleep 30", janitor)

      :ok = GenServer.stop(janitor)

      assert_gone([handle.pid])
      reader_gone!(reader)
    end

    # A home as a runner's lays it out, and a reader of its fifo as the
    # launcher starts one, with no runner ever opening the fifo to write:
    # the reader waits in its open, which is where a runner ended before
    # its shell opened the fifo leaves it. Whatever the test leaves, the
    # reader is killed and seen gone, then the home removed, when it ends.
    defp stranded_reader! do
      home =
        Path.join(System.tmp_dir!(), "locus_spawn_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(home)
      on_exit(fn -> File.rm_rf!(home) end)
      log = Path.join(home, "stderr")
      {_out, 0} = System.cmd("mkfifo", ["-m", "600", log], env: no_env())
      reader = Port.open({:spawn_executable, "/bin/cat"}, [:binary, :stream, :eof, args: [log]])
      {:os_pid, os_pid} = Port.info(reader, :os_pid)

      on_exit(fn ->
        if running?(os_pid),
          do:
            System.cmd("/bin/kill", ["-KILL", Integer.to_string(os_pid)],
              stderr_to_stdout: true,
              env: no_env()
            )

        assert_gone([os_pid])
      end)

      {home, reader, os_pid}
    end

    test "a reader waiting on a fifo no runner opened ends when the home is removed" do
      {home, reader, os_pid} = stranded_reader!()
      assert running?(os_pid)

      assert :ok = DirectLauncher.remove_home(home)

      assert_receive {^reader, :eof}, 5_000
      Port.close(reader)
      assert_gone([os_pid])
      refute File.exists?(home)
    end

    test "removing a home whose reader has already ended does not wait on its fifo" do
      {home, reader, os_pid} = stranded_reader!()
      Port.close(reader)
      System.cmd("kill", ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true, env: no_env())
      assert_gone([os_pid])

      task = Task.async(fn -> DirectLauncher.remove_home(home) end)
      assert {:ok, :ok} = Task.yield(task, 5_000)
      refute File.exists?(home)
    end
  end
end
