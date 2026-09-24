# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Keeper.Direct do
  @moduledoc """
  The keeper for a machine without `cyfr-spawn`: a runner is a child
  process of this VM, started with the argv and the explicit environment
  the pool gives it and nothing inherited (`env -i`), as this VM's own
  user, in a temporary home of its own. Its control channel is its
  standard input and output (`OPUS_CONTROL_FD=0`), since a plain port
  hands a child no other descriptor; its standard error is a fifo in its
  home that a reader of its own relays to the process that spawned it, as
  `cyfr-spawn` relays a runner's, so its log lines are this VM's log's. It
  isolates nothing: a runner can read and signal this VM. A deployment
  runs the image, whose keeper isolates.

  This process is the janitor: it holds every runner's OS pid and home,
  monitors the process that spawned each, and kills the runner's process
  group when that process ends without releasing it, or when this VM's
  pool goes down with it. A release sends the group a term signal, gives
  the runner the grace to report what it holds, then kills what is left.

  ## arca:bypass-ok=D — entire module

  Every path is a runner's own temporary home, created when the runner is
  spawned and removed when it is released or its owner ends.
  """

  @behaviour Opus.Keeper

  use GenServer

  import Kernel, except: [send: 2]

  require Logger

  @stdio_fd "0"

  @impl Opus.Keeper
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  @doc "Start the janitor. Options: `:name` (default `#{inspect(__MODULE__)}`)."
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl Opus.Keeper
  def available(env, _opts) do
    if Opus.Settings.channel_inherited?(env),
      do:
        {:error,
         "a keeper channel was inherited (#{Opus.Settings.channel_env()}); only cyfr-spawn may start runners here"},
      else: :ok
  end

  @impl Opus.Keeper
  def spawn(%{runner: runner, argv: argv, env: env}) do
    home = Path.join(System.tmp_dir!(), "opus_runner_#{Cyfr.Hex.short()}")
    log = Path.join(home, "log")

    with :ok <- File.mkdir_p(Path.join(home, "tmp")),
         :ok <- File.chmod(home, 0o700),
         :ok <- mkfifo(log) do
      environment =
        home |> base_environment() |> Map.merge(env) |> Map.put("OPUS_CONTROL_FD", @stdio_fd)

      # The runner's standard error goes to the fifo, which its own reader
      # relays: the shell opens the fifo, then becomes the runner.
      port =
        Port.open({:spawn_executable, "/usr/bin/env"}, [
          :binary,
          :stream,
          :eof,
          :exit_status,
          :use_stdio,
          cd: home,
          args:
            ["-i"] ++
              Enum.map(environment, fn {k, v} -> "#{k}=#{v}" end) ++
              ["/bin/sh", "-c", ~s(exec "$@" 2>"$0"), log] ++ argv
        ])

      relay = Port.open({:spawn_executable, "/bin/cat"}, [:binary, :stream, :eof, args: [log]])

      os_pid =
        case Port.info(port, :os_pid) do
          {:os_pid, pid} -> pid
          _ -> nil
        end

      case watch(os_pid, home, runner) do
        :ok ->
          {:ok, %{port: port, log: relay, os_pid: os_pid, home: home, runner: runner},
           [{:spawned, os_pid}, :attached]}

        {:error, reason} ->
          # No janitor to reap it: the runner is ended here and now.
          signal(os_pid, "KILL")
          Port.close(port)
          remove_home(home)
          {:error, {:spawn_failed, reason}}
      end
    else
      {:error, reason} ->
        File.rm_rf(home)
        {:error, {:spawn_failed, reason}}
    end
  end

  defp mkfifo(path) do
    case System.cmd("mkfifo", ["-m", "600", path], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, _status} -> {:error, {:mkfifo, String.trim(output)}}
    end
  rescue
    e in ErlangError -> {:error, {:mkfifo, Exception.message(e)}}
  end

  defp watch(os_pid, home, runner) do
    GenServer.call(janitor(), {:watch, os_pid, home, runner})
  catch
    :exit, _reason -> {:error, :janitor_down}
  end

  @impl Opus.Keeper
  def handle_message(%{port: port} = channel, {port, {:data, data}}),
    do: {:events, [{:control, data}], channel}

  def handle_message(%{port: port} = channel, {port, :eof}),
    do: {:events, [:control_closed], channel}

  def handle_message(%{port: port} = channel, {port, {:exit_status, status}}) do
    GenServer.cast(janitor(), {:gone, channel.os_pid})
    remove_home(channel.home)
    {:events, [{:exited, ended(status)}, :released], channel}
  end

  # What the runner wrote to its standard error, as it wrote it.
  def handle_message(%{log: log} = channel, {log, {:data, data}}),
    do: {:events, [{:log, data}], channel}

  def handle_message(%{log: log} = channel, {log, :eof}) do
    Port.close(log)
    {:events, [], channel}
  end

  def handle_message(_channel, _message), do: :unknown

  @impl Opus.Keeper
  def send(%{port: port}, data) do
    if Port.command(port, data), do: :ok, else: {:error, :busy}
  rescue
    ArgumentError -> {:error, :closed}
  end

  # The signals go from the caller, so a runner is ended even when the
  # janitor is gone; only the kill after a grace is the janitor's timer.
  @impl Opus.Keeper
  def release(%{os_pid: os_pid}, 0), do: signal(os_pid, "KILL")

  def release(%{os_pid: os_pid}, grace_ms) when is_integer(grace_ms) and grace_ms > 0 do
    signal(os_pid, "TERM")
    GenServer.cast(janitor(), {:kill_after, os_pid, grace_ms})
  end

  # A plain child process gets no cgroup of its own, so no bound.
  @impl Opus.Keeper
  def memory_bytes(_opts), do: nil

  # A spawn fails here only when its home or its janitor cannot be had.
  @impl Opus.Keeper
  def refusal(_reason),
    do: %{reason: "spawn_failed", message: "a runner could not be started on this machine"}

  @impl Opus.Keeper
  def stats, do: :unknown

  # What the keeper would set for a runner of its own: a home and a
  # temporary directory the runner can write, the user it runs as, and a
  # search path for the release's scripts.
  defp base_environment(home) do
    user = System.get_env("USER") || "opus"

    %{
      "HOME" => home,
      "TMPDIR" => Path.join(home, "tmp"),
      "USER" => user,
      "LOGNAME" => user,
      "PATH" => System.get_env("PATH") || "/usr/local/bin:/usr/bin:/bin"
    }
  end

  # A port reports a child ended by a signal as 128 plus the signal's number.
  defp ended(status) when status > 128, do: {:signal, "SIG#{status - 128}"}
  defp ended(status), do: {:status, status}

  defp janitor, do: __MODULE__

  # ---------------------------------------------------------------------------
  # The janitor
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(_opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{runners: %{}}}
  end

  @impl GenServer
  def handle_call({:watch, os_pid, home, runner}, {owner, _tag}, state) do
    entry = %{owner: owner, monitor: Process.monitor(owner), home: home, runner: runner}
    {:reply, :ok, %{state | runners: Map.put(state.runners, os_pid, entry)}}
  end

  @impl GenServer
  def handle_cast({:kill_after, os_pid, grace_ms}, state) do
    if Map.has_key?(state.runners, os_pid),
      do: Process.send_after(self(), {:kill, os_pid}, grace_ms)

    {:noreply, state}
  end

  def handle_cast({:gone, os_pid}, state) do
    {entry, runners} = Map.pop(state.runners, os_pid)
    if entry, do: Process.demonitor(entry.monitor, [:flush])
    {:noreply, %{state | runners: runners}}
  end

  @impl GenServer
  def handle_info({:kill, os_pid}, state) do
    if Map.has_key?(state.runners, os_pid), do: signal(os_pid, "KILL")
    {:noreply, state}
  end

  # The process that spawned the runner is gone without releasing it: the
  # runner is reaped at once, and its home with it.
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Enum.find(state.runners, fn {_os_pid, entry} -> entry.monitor == monitor end) do
      {os_pid, entry} ->
        signal(os_pid, "KILL")
        remove_home(entry.home)
        {:noreply, %{state | runners: Map.delete(state.runners, os_pid)}}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(msg, state) do
    Cyfr.LoggerContext.unexpected(__MODULE__, msg)
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    for {os_pid, entry} <- state.runners do
      signal(os_pid, "KILL")
      remove_home(entry.home)
    end

    :ok
  end

  @doc false
  # A runner's home, and with it the fifo its standard error went to. The
  # relay reading the fifo blocks in its open until a writer opens it, and
  # a runner ended before its shell opened the fifo never does: the relay
  # is no process of the runner's group, so no signal reaches it, and
  # removing the fifo does not wake an open already waiting on it. Opening
  # the fifo for reading and writing never blocks, counts as the writer the
  # relay waits for, and closes as it is opened, so the relay reads its end
  # and exits; a relay that has ended already is not waited for.
  @spec remove_home(Path.t()) :: :ok
  def remove_home(home) do
    log = Path.join(home, "log")

    if File.exists?(log) do
      System.cmd("/bin/sh", ["-c", ~s(exec 3<>"$0"), log], stderr_to_stdout: true)
    end

    File.rm_rf(home)
    :ok
  rescue
    e ->
      Logger.warning(
        "[Opus.Keeper.Direct] releasing a runner's log relay failed: #{Exception.message(e)}"
      )

      File.rm_rf(home)
      :ok
  end

  # A port's child leads its own process group, so the group signal
  # reaches what the runner started; the direct one covers a child that
  # does not. The group is named after `--`: procps-ng's kill, Linux's,
  # reads a negative number after the signal as nothing it can signal and
  # still exits 0, and only past `--` as a process group, which BSD's
  # kill reads the same way.
  defp signal(nil, _signal), do: :ok

  defp signal(os_pid, signal) do
    for target <- [["--", "-#{os_pid}"], ["#{os_pid}"]] do
      System.cmd("kill", ["-#{signal}" | target], stderr_to_stdout: true)
    end

    :ok
  rescue
    e ->
      Logger.warning(
        "[Opus.Keeper.Direct] signalling runner #{os_pid} failed: #{Exception.message(e)}"
      )
  end
end
