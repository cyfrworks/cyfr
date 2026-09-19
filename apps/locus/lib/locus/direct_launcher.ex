# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.DirectLauncher do
  @moduledoc """
  The executor of the test environment, and of nothing else: a build runs
  as this node's own user, in a temporary home removed after it. It
  isolates nothing — a build can read and signal this node and every other
  build, and reach this node's environment through `/proc` — and it
  applies no memory bound: a build here may take whatever memory the
  machine gives it. `Locus.Executor` knows it under the test environment
  alone, so the suites can run a real toolchain on a machine without
  cyfr-spawn; no release and no development node builds through it, and
  the builds service refuses to serve without cyfr-spawn anywhere else
  (`Locus.Application`).

  ## arca:bypass-ok=D — entire module

  Every path is under the run's own temporary directory, created and
  removed within `run/2`.

  The command sees only the variables of its `env` and this launcher's
  `HOME`, `TMPDIR`, `USER`, `LOGNAME` and `PATH` (this node's search path,
  where a development machine's toolchains are); `env -i` clears the rest.
  Its stdin is read from a file and its stdout written to one, since a
  port carries one stream each way; its stderr is the port's output.

  A run past its deadline, or cancelled (`Locus.Executor.cancel/1`), has
  its process group killed before `run/2` answers. A run whose caller dies
  is ended by a janitor that outlives the caller: it kills the process
  group and removes the run's directory.
  """

  @behaviour Locus.Executor

  require Logger

  alias Locus.Executor.Log

  @impl Locus.Executor
  def run(%{argv: argv, env: env, stdin: stdin}, opts) do
    root = Path.join(System.tmp_dir!(), "locus_build_#{Cyfr.Hex.short()}")
    home = Path.join(root, "home")
    input = Path.join(root, "stdin")
    output = Path.join(root, "stdout")

    with :ok <- File.mkdir_p(Path.join(home, "tmp")),
         :ok <- File.chmod(root, 0o700),
         :ok <- File.write(input, stdin) do
      launch(
        argv,
        command_env(env, home),
        %{root: root, home: home, input: input, output: output},
        opts
      )
    else
      {:error, reason} ->
        File.rm_rf(root)
        {:error, {:spawn_failed, reason}}
    end
  end

  defp command_env(env, home) do
    user = System.get_env("USER") || "build"

    Map.merge(env, %{
      "HOME" => home,
      "TMPDIR" => Path.join(home, "tmp"),
      "USER" => user,
      "LOGNAME" => user,
      "PATH" => System.get_env("PATH") || "/usr/local/bin:/usr/bin:/bin",
      # macOS tar otherwise adds AppleDouble entries for extended attributes.
      "COPYFILE_DISABLE" => "1"
    })
  end

  defp launch(argv, env, paths, opts) do
    on_output = Keyword.get(opts, :on_output, fn _line -> :ok end)
    deadline = System.monotonic_time(:millisecond) + Keyword.fetch!(opts, :timeout_ms)

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :use_stdio,
        cd: paths.home,
        args:
          [
            "-c",
            ~s(exec 2>&1 >"$1" <"$2" && shift 2 && exec "$@"),
            "locus-launch",
            paths.output,
            paths.input
          ] ++
            ["/usr/bin/env", "-i"] ++ Enum.map(env, fn {k, v} -> "#{k}=#{v}" end) ++ argv
      ])

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    janitor = watch(self(), os_pid, paths.root)

    result =
      case collect(port, Log.new(), on_output, deadline) do
        {:exit, status} ->
          read_output(status, paths.output, Keyword.fetch!(opts, :max_stdout_bytes))

        ended when ended in [:timeout, :cancelled] ->
          kill(os_pid)
          close(port)
          {:error, ended}
      end

    send(janitor, :done)
    File.rm_rf(paths.root)
    result
  end

  defp collect(port, log, on_output, deadline) do
    receive do
      {^port, {:data, data}} ->
        collect(port, Log.add(log, data, on_output), on_output, deadline)

      {^port, {:exit_status, status}} ->
        :ok = Log.finish(log, on_output)
        {:exit, status}

      {Locus.Executor, :cancel} ->
        :cancelled
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> :timeout
    end
  end

  # The kill ends the command, whose exit closes the port: by now it may be
  # closed already, which `Port.close/1` raises on. What the port sent
  # before it closed is of no use to anyone.
  defp close(port) do
    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    drain(port)
  end

  defp drain(port) do
    receive do
      {^port, _message} -> drain(port)
    after
      0 -> :ok
    end
  end

  defp read_output(status, output, max_bytes) do
    case File.stat(output) do
      {:ok, %File.Stat{size: size}} when size > max_bytes ->
        {:error, {:output_too_large, max_bytes}}

      {:ok, _} ->
        case File.read(output) do
          {:ok, stdout} -> {:ok, %{exit: {:status, status}, stdout: stdout}}
          {:error, reason} -> {:error, {:spawn_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:spawn_failed, reason}}
    end
  end

  # Kills the run's process group and removes its directory if the caller
  # dies before the run ends.
  defp watch(caller, os_pid, root) do
    spawn(fn ->
      ref = Process.monitor(caller)

      receive do
        :done ->
          :ok

        {:DOWN, ^ref, :process, _pid, _reason} ->
          kill(os_pid)
          File.rm_rf(root)
      end
    end)
  end

  # A port's child leads its own process group, so the group kill reaches
  # what the build started; the direct kill covers a child that does not.
  # The group's negative id follows `--`: without it the procps `kill` of
  # a Linux host reads it as an option, kills nothing and exits 0.
  defp kill(nil), do: :ok

  defp kill(os_pid) do
    for target <- [["--", "-#{os_pid}"], ["#{os_pid}"]] do
      System.cmd("kill", ["-9" | target], stderr_to_stdout: true)
    end

    :ok
  rescue
    e ->
      Logger.warning(
        "[Locus.DirectLauncher] killing build process #{os_pid} failed: #{Exception.message(e)}"
      )
  end
end
