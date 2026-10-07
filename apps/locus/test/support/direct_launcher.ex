# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.DirectLauncher do
  @moduledoc """
  The executor of the test environment, and of nothing else: a build runs
  as this node's own user, in a temporary home removed after it. It
  isolates nothing — a build can read and signal this node and every other
  build, and reach this node's environment through `/proc` — and it
  applies no memory bound: a build here may take whatever memory the
  machine gives it. It is compiled from the test support alone and named
  by the test build's application environment
  (`Locus.Executor.direct_launcher/0`), so the suites can run a real
  toolchain on a machine without cyfr-keeper; no release and no
  development node compiles it or builds through it, and
  the builds service refuses to serve without cyfr-keeper anywhere else
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

  ## A long-lived process

  As the test environment's `Locus.Launcher` it starts a process the same
  way, as this node's own user with an environment built from nothing and
  no bound, and a process of this node's own holds it for its owner: its
  stdout is the port's output and its stderr a fifo in its home that a
  reader of its own relays, so the two streams stay apart, and each
  reaches the owner as it arrives. A release sends the process group a
  term signal and, once the grace passes, the kill; the process's exit
  kills what is left of its group, removes its home and reports it
  released. Every pool is one uid wide, and none is quarantined. An owner
  that dies has the group killed and the home removed at once.
  """

  @behaviour Locus.Executor
  @behaviour Locus.Launcher

  import Kernel, except: [send: 2]

  require Logger

  alias Locus.DirectLauncher.Child
  alias Locus.Executor.Log

  # A well-formed spawn id, so a signal is checked as the codec checks one.
  @probe_spawn_id String.duplicate("0", 32)

  @impl Locus.Executor
  def run(%{argv: argv, env: env, stdin: stdin}, opts) do
    root = Path.join(System.tmp_dir!(), "locus_build_#{Prima.Hex.short()}")
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

  # macOS tar otherwise adds AppleDouble entries for extended attributes.
  defp command_env(env, home),
    do: Map.merge(env, Map.put(base_env(home), "COPYFILE_DISABLE", "1"))

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

    Kernel.send(janitor, :done)
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

  # ————— a long-lived process —————

  @impl Locus.Launcher
  def spawn(_opts, %{argv: argv, env: env}) do
    ref = make_ref()

    case GenServer.start(Child, {self(), ref, argv, env}) do
      # The child sent its handle before its start answered, and messages
      # between two processes arrive in the order they were sent: the
      # handle is here already, however soon the process ended.
      {:ok, _child} ->
        receive do
          {Child, ^ref, handle} -> {:ok, handle}
        end

      {:error, reason} ->
        {:error, {:spawn_failed, reason}}
    end
  end

  @impl Locus.Launcher
  def send(%{server: child}, data), do: call(child, {:stdin, IO.iodata_to_binary(data)})

  @impl Locus.Launcher
  def signal(%{server: child}, sig) when is_binary(sig) do
    if signal?(sig), do: call(child, {:signal, sig}), else: {:error, :unencodable}
  end

  @impl Locus.Launcher
  def release(_opts, %{server: child}, grace_ms) when is_integer(grace_ms) and grace_ms >= 0,
    do: GenServer.cast(child, {:release, grace_ms})

  @impl Locus.Launcher
  def pool_stats(_opts, pool) when is_binary(pool), do: {:ok, %{size: 1, free: 1, quarantined: 0}}

  defp call(child, request) do
    GenServer.call(child, request)
  catch
    :exit, _reason -> {:error, :unknown_spawn}
  end

  # The signals a spawn may be sent are cyfr-keeper's, as its codec reads
  # a `signal` request.
  defp signal?(sig) do
    _ = Prima.KeeperProtocol.encode(%{type: :signal, spawn_id: @probe_spawn_id, sig: sig})
    true
  rescue
    ArgumentError -> false
  end

  @doc false
  # The launcher's own variables beside the command's: a home and a
  # temporary directory of its own, this node's user and search path.
  @spec base_env(Path.t()) :: %{String.t() => String.t()}
  def base_env(home) do
    user = System.get_env("USER") || "build"

    %{
      "HOME" => home,
      "TMPDIR" => Path.join(home, "tmp"),
      "USER" => user,
      "LOGNAME" => user,
      "PATH" => System.get_env("PATH") || "/usr/local/bin:/usr/bin:/bin"
    }
  end

  @doc false
  # A process group's signal and its leader's: a port's child leads its
  # own group, so the group signal reaches what it started, and the direct
  # one covers a child that does not. The group's negative id follows
  # `--`: without it the procps `kill` of a Linux host reads it as an
  # option, signals nothing and exits 0.
  @spec signal_group(non_neg_integer() | nil, String.t()) :: :ok
  def signal_group(nil, _signal), do: :ok

  def signal_group(os_pid, signal) do
    for target <- [["--", "-#{os_pid}"], ["#{os_pid}"]] do
      System.cmd("kill", ["-#{signal}" | target], stderr_to_stdout: true)
    end

    :ok
  rescue
    e ->
      Logger.warning(
        "[Locus.DirectLauncher] signalling process #{os_pid} failed: #{Exception.message(e)}"
      )
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

  defp kill(os_pid), do: signal_group(os_pid, "KILL")
end

defmodule Locus.DirectLauncher.Child do
  @moduledoc false
  # One long-lived process of `Locus.DirectLauncher` and its owner's
  # events. The process runs under `env -i` with its standard error on a
  # fifo in its home, which `cat` relays: a port carries one stream each
  # way, and stdout and stderr stay apart.
  #
  # arca:bypass-ok=D — entire module: every path is the process's own
  # temporary home, created here and removed when the process ends or its
  # owner does.

  use GenServer

  require Logger

  alias Locus.DirectLauncher

  # How long the stderr relay has, after the process's exit, to deliver
  # what the process wrote before the release is reported.
  @drain_timeout_ms 1_000

  # A port reports a child ended by a signal as 128 and the signal's number.
  @signals %{
    1 => "SIGHUP",
    2 => "SIGINT",
    3 => "SIGQUIT",
    6 => "SIGABRT",
    9 => "SIGKILL",
    10 => "SIGUSR1",
    12 => "SIGUSR2",
    13 => "SIGPIPE",
    14 => "SIGALRM",
    15 => "SIGTERM"
  }

  @impl true
  def init({owner, ref, argv, env}) do
    home = Path.join(System.tmp_dir!(), "locus_spawn_#{Prima.Hex.short()}")
    log = Path.join(home, "stderr")

    with :ok <- File.mkdir_p(Path.join(home, "tmp")),
         :ok <- File.chmod(home, 0o700),
         :ok <- mkfifo(log) do
      environment = Map.merge(env, DirectLauncher.base_env(home))

      # The shell opens the fifo for the process's standard error, then
      # becomes the process.
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

      # The handle goes to the owner's mailbox, not to a call of its own: a
      # process that ends at once stops its child before such a call
      # arrives. It precedes every event.
      handle = %{ref: ref, spawn_id: nil, uid: nil, pid: os_pid, server: self()}
      Kernel.send(owner, {__MODULE__, ref, handle})
      Kernel.send(owner, {DirectLauncher, ref, :attached})

      {:ok,
       %{
         owner: owner,
         monitor: Process.monitor(owner),
         ref: ref,
         port: port,
         relay: relay,
         os_pid: os_pid,
         home: home,
         log: log,
         exited: false,
         ended: nil,
         relay_open: true
       }}
    else
      {:error, reason} ->
        File.rm_rf(home)
        {:stop, reason}
    end
  end

  defp mkfifo(path) do
    case System.cmd("mkfifo", ["-m", "600", path], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {_output, _status} -> {:error, :mkfifo}
    end
  rescue
    ErlangError -> {:error, :mkfifo}
  end

  @impl true
  def handle_call({:stdin, _data}, _from, %{exited: true} = state),
    do: {:reply, {:error, :stdin_closed}, state}

  def handle_call({:stdin, data}, _from, state) do
    Port.command(state.port, data)
    {:reply, :ok, state}
  rescue
    ArgumentError -> {:reply, {:error, :stdin_closed}, state}
  end

  def handle_call({:signal, sig}, _from, state) do
    unless state.exited, do: DirectLauncher.signal_group(state.os_pid, trim_sig(sig))
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:release, _grace_ms}, %{exited: true} = state), do: {:noreply, state}

  def handle_cast({:release, 0}, state) do
    DirectLauncher.signal_group(state.os_pid, "KILL")
    {:noreply, state}
  end

  def handle_cast({:release, grace_ms}, state) do
    DirectLauncher.signal_group(state.os_pid, "TERM")
    Process.send_after(self(), :kill, grace_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    notify(state, {:stdout, data})
    {:noreply, state}
  end

  def handle_info({port, :eof}, %{port: port} = state), do: {:noreply, state}

  # The leader is gone: what is left of its group goes with it, as
  # cyfr-keeper retires a spawn whose leader exited.
  # The exit is told once the streams are drained, so an owner hears every
  # byte the process wrote before it hears that the process is gone.
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    DirectLauncher.signal_group(state.os_pid, "KILL")
    Process.send_after(self(), :drained, @drain_timeout_ms)
    finish_if_drained(%{state | exited: true, ended: ended(status)})
  end

  def handle_info({relay, {:data, data}}, %{relay: relay} = state) do
    notify(state, {:stderr, data})
    {:noreply, state}
  end

  def handle_info({relay, :eof}, %{relay: relay} = state) do
    close(relay)
    finish_if_drained(%{state | relay_open: false})
  end

  def handle_info(:drained, state), do: finish(state)

  def handle_info(:kill, state) do
    unless state.exited, do: DirectLauncher.signal_group(state.os_pid, "KILL")
    {:noreply, state}
  end

  # The owner is gone without releasing the process: it is ended at once,
  # and nothing is left to tell.
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{monitor: monitor} = state) do
    DirectLauncher.signal_group(state.os_pid, "KILL")
    {:stop, :normal, %{state | owner: nil}}
  end

  def handle_info(message, state) do
    Prima.LoggerContext.unexpected(__MODULE__, message)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    unless state.exited, do: DirectLauncher.signal_group(state.os_pid, "KILL")
    remove_home(state)
    :ok
  end

  # What the owner writes to the process may carry a credential: no crash
  # report shows more of it than its size.
  @impl true
  def format_status(status) do
    Map.new(status, fn
      {:message, {:stdin, data}} -> {:message, {:stdin, {:redacted, byte_size(data)}}}
      {:message, {port, {:data, data}}} -> {:message, {port, {:data, byte_size(data)}}}
      {:log, _log} -> {:log, []}
      other -> other
    end)
  end

  defp finish_if_drained(%{exited: true, relay_open: false} = state), do: finish(state)
  defp finish_if_drained(state), do: {:noreply, state}

  defp finish(state) do
    remove_home(state)
    if state.ended, do: notify(state, state.ended)
    notify(state, :released)
    {:stop, :normal, %{state | exited: true}}
  end

  defp notify(%{owner: owner, ref: ref}, event) when is_pid(owner),
    do: Kernel.send(owner, {DirectLauncher, ref, event})

  defp notify(_state, _event), do: :ok

  defp ended(status) when status > 128,
    do: {:exited, nil, Map.get(@signals, status - 128, "SIG#{status - 128}")}

  defp ended(status), do: {:exited, status, nil}

  defp trim_sig("SIG" <> name), do: name

  defp close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  # The home, and with it the fifo stderr went to. A relay still blocked
  # in its open of the fifo, because the process ended before its shell
  # opened it, is released by an open for reading and writing, which
  # never blocks and closes at once.
  defp remove_home(%{home: home, log: log}) do
    if File.exists?(log), do: System.cmd("/bin/sh", ["-c", ~s(exec 3<>"$0"), log])
    File.rm_rf(home)
    :ok
  rescue
    ErlangError -> File.rm_rf(home)
  end
end
