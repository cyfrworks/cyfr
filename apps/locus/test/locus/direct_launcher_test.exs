# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.DirectLauncherTest do
  @moduledoc """
  The test environment's executor ends what it started on every path: at
  the command's exit, at its deadline and at a cancel it kills the
  command's process group before it answers, and when its caller dies a
  janitor that outlives the caller kills the group and removes the run's
  directory. It gives the command an environment built from nothing, and
  no memory bound.
  """

  use ExUnit.Case, async: true

  alias Locus.DirectLauncher

  defp wait_until(check, attempts \\ 200) do
    cond do
      check.() -> :ok
      attempts == 0 -> flunk("condition never held")
      true -> Process.sleep(50) && wait_until(check, attempts - 1)
    end
  end

  defp alive?(os_pid) do
    {_out, status} = System.cmd("kill", ["-0", os_pid], stderr_to_stdout: true)
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
    wait_until(fn ->
      match?({:ok, _}, File.read(file)) and
        length(String.split(File.read!(file), "\n", trim: true)) == 3
    end)

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
    System.put_env("LOCUS_DL_SECRET", "of this node's")
    on_exit(fn -> System.delete_env("LOCUS_DL_SECRET") end)

    assert {:ok, %{exit: {:status, 0}, stdout: env}} = run("env", env: %{"GIVEN" => "yes"})

    names = for line <- String.split(env, "\n", trim: true), do: line |> String.split("=") |> hd()

    assert Enum.sort(names -- ~w(PWD SHLVL _ OLDPWD)) ==
             Enum.sort(~w(COPYFILE_DISABLE GIVEN HOME LOGNAME PATH TMPDIR USER))

    refute env =~ "LOCUS_DL_SECRET"
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
    for os_pid <- os_pids, do: wait_until(fn -> not alive?(os_pid) end)
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

    for os_pid <- os_pids, do: wait_until(fn -> not alive?(os_pid) end)
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

    for os_pid <- os_pids, do: wait_until(fn -> not alive?(os_pid) end)
    wait_until(fn -> not File.exists?(home) end)
    wait_until(fn -> not File.exists?(Path.dirname(home)) end)
  end
end
