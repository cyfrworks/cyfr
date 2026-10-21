# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.DirectLauncher do
  @moduledoc """
  The launcher of the test environment, and of nothing else, for all three
  roles: the executor builds run through, the launcher backends run
  through, and, through its runtime face (`Locus.DirectLauncher.Runner`),
  the keeper the runtime's runners start through. Everything it starts
  runs as this node's own user, in a temporary home removed after it. It
  isolates nothing — what it starts can read and signal this node and
  everything else it started, and reach this node's environment and
  network — and it applies no memory bound: a process here may take
  whatever memory the machine gives it. It is compiled from the test
  support alone and named by the test build's configuration alone
  (`Locus.Executor.direct_launcher/0`, `Locus.Runtime.Keeper.direct_keeper/0`),
  so the suites can run a real toolchain and real runners on a machine
  without cyfr-locus; no release and no development node compiles it or
  starts anything through it, and every role refuses to serve without
  cyfr-locus anywhere else (`Locus.Application`, `Locus.Runtime`).

  ## arca:bypass-ok=D — entire module

  Every path is under the run's own temporary directory, created and
  removed within `run/2`.

  The command sees only the variables of its `env` and this launcher's
  `HOME`, `TMPDIR`, `USER`, `LOGNAME` and `PATH` (this node's search path,
  where a development machine's toolchains are); `env -i` clears the rest.
  Its stdin is read from a file and its stdout written to one, since a
  port carries one stream each way; its stderr is the port's output.

  The launcher's own tools (`sh`, `env`, `cat`, `kill`, `mkfifo`) are
  named by absolute path, never looked up through this node's PATH: a
  test may make a toolchain absent by moving the node's PATH, and a kill
  looked up through it would be lost, the process left running and the
  runtime's pool waiting for a retirement that never comes.

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
  term signal and, once the grace passes, the kill. One exit policy
  serves every process: its leader's exit kills what is left of its
  group, the exit is told once its stderr has ended (or a second has
  passed), with the signal named as cyfr-locus names it, then its home is
  removed and it is reported released, the last. An owner that dies has
  the group killed and the home removed at once. The stderr reader is
  stopped on every one of those paths, ended or not: a reader left waiting
  on a fifo outlives the suite. Every pool is one uid wide, and none is
  quarantined.

  A spec with `control: true` is a runner's: its standard input and
  output are its control channel (`RUNTIME_CONTROL_FD=0`), since a port
  hands a child no other descriptor, and its relay (`Prima.RunnerRelay`)
  is a unix socket in its home (`RUNTIME_RELAY_SOCKET`) it connects to,
  carried by a process of its own as cyfr-locus carries stream 5. Its
  owner hears what `Locus.Keeper`'s owner of such a spawn hears
  (`t:Locus.Launcher.control_event/0`), its spawn id and uid nil.
  """

  @behaviour Locus.Executor
  @behaviour Locus.Launcher

  import Kernel, except: [send: 2]

  require Logger

  alias Locus.DirectLauncher.Child
  alias Locus.Executor.Log

  @kill "/bin/kill"

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

  @doc """
  Start `spec` for the calling process, its owner. `opts` may name a
  `:janitor`, a `Locus.DirectLauncher.Runner` that ends the process when
  it goes down; the process refuses to start without it when named.

  `strand_reader: true` exists for the launcher's own tests alone: the
  process never opens its stderr fifo, and nothing that removes its home
  wakes the reader, which stays blocked in its open of the fifo until the
  reader is stopped. That is the state a reader is left in when its
  process ends before its shell opens the fifo and the wake misses it.
  """
  @impl Locus.Launcher
  def spawn(opts, %{argv: argv, env: env} = spec) do
    ref = make_ref()
    mode = if Map.get(spec, :control) == true, do: :control, else: :stdio
    janitor = if Keyword.keyword?(opts), do: Keyword.get(opts, :janitor)
    strand? = Keyword.keyword?(opts) and Keyword.get(opts, :strand_reader, false) == true

    case GenServer.start(Child, {self(), ref, argv, env, mode, janitor, strand?}) do
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
  def send_control(%{server: child}, data),
    do: call(child, {:control, IO.iodata_to_binary(data)})

  @impl Locus.Launcher
  def send_relay(_handle, ""), do: :ok

  def send_relay(%{server: child}, data) do
    GenServer.call(child, {:relay, IO.iodata_to_binary(data)})
  catch
    :exit, _reason -> {:error, :relay_closed}
  end

  @impl Locus.Launcher
  def close_relay(%{server: child}), do: GenServer.cast(child, :close_relay)

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

  # The signals a spawn may be sent are cyfr-locus's, as its codec reads
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
  # one covers a child that does not. The group is named after `--`:
  # procps-ng's kill, Linux's, reads a negative number after the signal as
  # nothing it can signal and still exits 0, and only past `--` as a
  # process group, which BSD's kill reads the same way.
  @spec signal_group(non_neg_integer() | nil, String.t()) :: :ok
  def signal_group(nil, _signal), do: :ok

  def signal_group(os_pid, signal) do
    for target <- [["--", "-#{os_pid}"], ["#{os_pid}"]] do
      System.cmd(@kill, ["-#{signal}" | target], stderr_to_stdout: true)
    end

    :ok
  rescue
    e ->
      Logger.error(
        "[Locus.DirectLauncher] signalling process #{os_pid} failed: #{Exception.message(e)}"
      )
  end

  @doc false
  # A process's stderr reader, ended whatever it waits in: its read of a
  # fifo a writer still holds, or its open of one no writer ever opened.
  # It is no process of the group it reads, so no group signal reaches it.
  @spec stop_reader(port() | nil, non_neg_integer() | nil) :: :ok
  def stop_reader(reader, os_pid) do
    if os_pid, do: System.cmd(@kill, ["-KILL", "#{os_pid}"], stderr_to_stdout: true)

    if reader do
      try do
        Port.close(reader)
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  rescue
    e ->
      Logger.warning(
        "[Locus.DirectLauncher] stopping a stderr reader failed: #{Exception.message(e)}"
      )
  end

  @doc false
  # A process's home, and with it the fifo its standard error went to. A
  # reader still blocked in its open of the fifo, because the process
  # ended before its shell opened it, is released by an open for reading
  # and writing, which never blocks, counts as the writer the reader waits
  # for, and closes as it is opened, so the reader reads its end and
  # exits; a reader that has ended already is not waited for. Removing the
  # fifo alone does not wake an open already waiting on it. The wake can
  # miss a reader that opens after it, so a reader is stopped as well
  # (`stop_reader/2`); `wake: false` leaves it out, for the launcher's
  # tests of that stop alone.
  @spec remove_home(Path.t(), boolean()) :: :ok
  def remove_home(home, wake \\ true) do
    log = Path.join(home, "stderr")

    if wake and File.exists?(log) do
      System.cmd("/bin/sh", ["-c", ~s(exec 3<>"$0"), log], stderr_to_stdout: true)
    end

    File.rm_rf(home)
    :ok
  rescue
    e ->
      Logger.warning(
        "[Locus.DirectLauncher] releasing a stderr reader failed: #{Exception.message(e)}"
      )

      File.rm_rf(home)
      :ok
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
  # way, and stdout and stderr stay apart. A runner's (`:control`) also
  # has its relay, a unix socket in its home accepted by a process of this
  # one's.
  #
  # arca:bypass-ok=D — entire module: every path is the process's own
  # temporary home, created here and removed when the process ends or its
  # owner does.

  use GenServer

  require Logger

  alias Locus.DirectLauncher

  # How long the stderr reader has, after the process's exit, to deliver
  # what the process wrote before the exit and the release are reported.
  @drain_timeout_ms 1_000

  @relay_socket "relay.sock"

  @mkfifo "/usr/bin/mkfifo"

  # A port reports a child ended by a signal as 128 and the signal's
  # number; the name is cyfr-locus's for it.
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
  def init({owner, ref, argv, env, mode, janitor, strand?}) do
    Process.flag(:trap_exit, true)
    home = Path.join(System.tmp_dir!(), "locus_spawn_#{Prima.Hex.short()}")
    log = Path.join(home, "stderr")

    with :ok <- File.mkdir_p(Path.join(home, "tmp")),
         :ok <- File.chmod(home, 0o700),
         :ok <- mkfifo(log),
         {:ok, relay, relay_env} <- relay(mode, home) do
      environment = env |> Map.merge(DirectLauncher.base_env(home)) |> Map.merge(relay_env)

      # The shell opens the fifo for the process's standard error, then
      # becomes the process; a stranded reader's process never opens it.
      script = if strand?, do: ~s(exec "$@"), else: ~s(exec "$@" 2>"$0")

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
              ["/bin/sh", "-c", script, log] ++ argv
        ])

      reader =
        Port.open({:spawn_executable, "/bin/cat"}, [
          :binary,
          :stream,
          :eof,
          :exit_status,
          args: [log]
        ])

      state = %{
        owner: owner,
        monitor: Process.monitor(owner),
        ref: ref,
        mode: mode,
        port: port,
        reader: reader,
        relay: relay,
        os_pid: os_pid(port),
        reader_os_pid: os_pid(reader),
        home: home,
        exited: false,
        ended: nil,
        stderr_open: true,
        reader_exited: false,
        control_open: mode == :control,
        relay_open: mode == :control,
        janitor: janitor,
        wake_reader: not strand?,
        cleaned: false
      }

      case watch(janitor, state) do
        :ok ->
          # The handle goes to the owner's mailbox, not to a call of its
          # own: a process that ends at once stops its child before such a
          # call arrives. It precedes every event.
          handle = %{
            ref: ref,
            spawn_id: nil,
            uid: nil,
            pid: state.os_pid,
            server: self(),
            home: home
          }

          Kernel.send(owner, {__MODULE__, ref, handle})
          if mode == :control, do: notify(state, {:spawned, nil, nil, state.os_pid})
          notify(state, :attached)
          {:ok, state}

        {:error, reason} ->
          DirectLauncher.signal_group(state.os_pid, "KILL")
          cleanup(state)
          {:stop, reason}
      end
    else
      {:error, reason} ->
        File.rm_rf(home)
        {:stop, reason}
    end
  end

  defp os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      _ -> nil
    end
  end

  defp mkfifo(path) do
    case System.cmd(@mkfifo, ["-m", "600", path], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {_output, _status} -> {:error, :mkfifo}
    end
  rescue
    ErlangError -> {:error, :mkfifo}
  end

  # A runner's relay: a unix socket in its home that the runner connects
  # to, listened on before the runner starts, and a process of this one's
  # that accepts the one connection and carries its bytes both ways, as
  # cyfr-locus carries stream 5.
  defp relay(:stdio, _home), do: {:ok, nil, %{}}

  defp relay(:control, home) do
    path = Path.join(home, @relay_socket)
    owner = self()

    with {:ok, listener} <-
           :gen_tcp.listen(0, [:binary, packet: :raw, active: false, ifaddr: {:local, path}]) do
      relay = spawn_link(fn -> relay_accept(listener, owner) end)

      case :gen_tcp.controlling_process(listener, relay) do
        :ok ->
          Kernel.send(relay, :go)
          {:ok, relay, %{"RUNTIME_CONTROL_FD" => "0", "RUNTIME_RELAY_SOCKET" => path}}

        {:error, reason} ->
          :gen_tcp.close(listener)
          Process.exit(relay, :kill)
          {:error, {:relay, reason}}
      end
    end
  end

  # A runner connects with its first assignment, however long it waits
  # for one; this process is linked to the child, and ends with it.
  defp relay_accept(listener, owner) do
    receive do
      :go -> :ok
    end

    case :gen_tcp.accept(listener) do
      {:ok, conn} ->
        :gen_tcp.close(listener)
        :ok = :inet.setopts(conn, active: true)
        relay_loop(conn, owner)

      {:error, _reason} ->
        :gen_tcp.close(listener)
        Kernel.send(owner, {self(), :relay_closed})
    end
  end

  defp relay_loop(conn, owner) do
    receive do
      {:tcp, ^conn, data} ->
        Kernel.send(owner, {self(), {:relay, data}})
        relay_loop(conn, owner)

      {:tcp_closed, ^conn} ->
        Kernel.send(owner, {self(), :relay_closed})

      {:tcp_error, ^conn, _reason} ->
        Kernel.send(owner, {self(), :relay_closed})

      {:write, data} ->
        _ = :gen_tcp.send(conn, data)
        relay_loop(conn, owner)

      :close ->
        :gen_tcp.close(conn)
    end
  end

  defp watch(nil, _state), do: :ok

  defp watch(janitor, state) do
    GenServer.call(
      janitor,
      {:watch, self(), state.os_pid, state.reader_os_pid, state.home, state.wake_reader}
    )
  catch
    :exit, _reason -> {:error, :janitor_down}
  end

  @impl true
  def handle_call({stream, _data}, _from, %{exited: true} = state)
      when stream in [:stdin, :control],
      do: {:reply, {:error, closed(stream)}, state}

  def handle_call({stream, data}, _from, %{mode: mode} = state)
      when (stream == :stdin and mode == :stdio) or (stream == :control and mode == :control) do
    Port.command(state.port, data)
    {:reply, :ok, state}
  rescue
    ArgumentError -> {:reply, {:error, closed(stream)}, state}
  end

  def handle_call({stream, _data}, _from, state) when stream in [:stdin, :control],
    do: {:reply, {:error, :unknown_spawn}, state}

  def handle_call({:relay, data}, _from, %{relay_open: true, relay: relay} = state)
      when relay != nil do
    Kernel.send(relay, {:write, data})
    {:reply, :ok, state}
  end

  def handle_call({:relay, _data}, _from, state), do: {:reply, {:error, :relay_closed}, state}

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

  def handle_cast(:close_relay, %{relay_open: true, relay: relay} = state) when relay != nil do
    Kernel.send(relay, :close)
    {:noreply, %{state | relay_open: false}}
  end

  def handle_cast(:close_relay, state), do: {:noreply, state}

  @impl true
  def handle_info({port, {:data, data}}, %{port: port, mode: :control} = state) do
    notify(state, {:control, data})
    {:noreply, state}
  end

  def handle_info({port, {:data, data}}, %{port: port} = state) do
    notify(state, {:stdout, data})
    {:noreply, state}
  end

  def handle_info({port, :eof}, %{port: port} = state), do: {:noreply, control_closed(state)}

  # The leader is gone: what is left of its group goes with it, as
  # cyfr-locus retires a spawn whose leader exited.
  # The exit is told once the streams are drained, so an owner hears every
  # byte the process wrote before it hears that the process is gone.
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    DirectLauncher.signal_group(state.os_pid, "KILL")
    Process.send_after(self(), :drained, @drain_timeout_ms)
    finish_if_drained(%{state | exited: true, ended: ended(state.mode, status)})
  end

  def handle_info({reader, {:data, data}}, %{reader: reader} = state) do
    notify(state, {:stderr, data})
    {:noreply, state}
  end

  def handle_info({reader, :eof}, %{reader: reader} = state),
    do: finish_if_drained(%{state | stderr_open: false})

  # The reader ended: its pid is no longer its, and nothing signals it.
  def handle_info({reader, {:exit_status, _status}}, %{reader: reader} = state) do
    reader_gone(state)
    finish_if_drained(%{state | reader_exited: true, stderr_open: false})
  end

  # What the runner wrote on its relay, as it wrote it, and the relay's end.
  def handle_info({relay, {:relay, data}}, %{relay: relay} = state) when relay != nil do
    notify(state, {:relay, data})
    {:noreply, state}
  end

  def handle_info({relay, :relay_closed}, %{relay: relay} = state) when relay != nil,
    do: {:noreply, relay_closed(state)}

  def handle_info({:EXIT, relay, _reason}, %{relay: relay} = state) when relay != nil,
    do: {:noreply, relay_closed(%{state | relay: nil})}

  def handle_info({:EXIT, _pid_or_port, _reason}, state), do: {:noreply, state}

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
    cleanup(state)
    :ok
  end

  # What the owner writes to the process, and what the process writes on
  # its relay, may carry a credential: no crash report shows more of it
  # than its size.
  @impl true
  def format_status(status) do
    Map.new(status, fn
      {:message, {stream, data}} when stream in [:stdin, :control, :relay] and is_binary(data) ->
        {:message, {stream, {:redacted, byte_size(data)}}}

      {:message, {port, {:data, data}}} when is_binary(data) ->
        {:message, {port, {:data, byte_size(data)}}}

      {:message, {relay, {:relay, data}}} when is_binary(data) ->
        {:message, {relay, {:relay, byte_size(data)}}}

      {:log, _log} ->
        {:log, []}

      other ->
        other
    end)
  end

  defp closed(:stdin), do: :stdin_closed
  defp closed(:control), do: :control_closed

  defp control_closed(%{control_open: true} = state) do
    notify(state, :control_closed)
    %{state | control_open: false}
  end

  defp control_closed(state), do: state

  defp relay_closed(%{relay_open: true} = state) do
    notify(state, :relay_closed)
    %{state | relay_open: false}
  end

  defp relay_closed(state), do: state

  defp finish_if_drained(%{exited: true, stderr_open: false} = state), do: finish(state)
  defp finish_if_drained(state), do: {:noreply, state}

  # A runner's control channel and relay are closed with it, if they were
  # not reported so already, as cyfr-locus closes them with the runner's
  # relay connection.
  defp finish(state) do
    state = state |> control_closed() |> relay_closed()
    state = cleanup(state)
    if state.ended, do: notify(state, state.ended)
    notify(state, :released)
    {:stop, :normal, %{state | exited: true}}
  end

  # The reader, the relay and the home, once: the reader is stopped
  # whether or not it reached its end, so none outlives the process.
  defp cleanup(%{cleaned: true} = state), do: state

  defp cleanup(state) do
    reader_os_pid = if state.reader_exited, do: nil, else: state.reader_os_pid
    :ok = DirectLauncher.stop_reader(state.reader, reader_os_pid)
    reader_gone(state)
    if state.relay, do: Process.exit(state.relay, :kill)
    :ok = DirectLauncher.remove_home(state.home, state.wake_reader)
    %{state | cleaned: true}
  end

  defp reader_gone(%{janitor: nil}), do: :ok
  defp reader_gone(%{janitor: janitor}), do: GenServer.cast(janitor, {:reader_gone, self()})

  defp notify(%{owner: owner, ref: ref}, event) when is_pid(owner),
    do: Kernel.send(owner, {DirectLauncher, ref, event})

  defp notify(_state, _event), do: :ok

  defp ended(mode, status) when status > 128,
    do: exit_event(mode, {:signal, Map.get(@signals, status - 128, "SIG#{status - 128}")})

  defp ended(mode, status), do: exit_event(mode, {:status, status})

  # A runner's owner hears the exit as cyfr-locus reports it, with no
  # memory bound to have reached; a long-lived process's as
  # `Locus.Launcher` spells it.
  defp exit_event(:control, exit), do: {:exited, exit, false}
  defp exit_event(:stdio, {:status, code}), do: {:exited, code, nil}
  defp exit_event(:stdio, {:signal, signal}), do: {:exited, nil, signal}

  defp trim_sig("SIG" <> name), do: name
end

defmodule Locus.DirectLauncher.Runner do
  @moduledoc """
  `Locus.DirectLauncher`'s face to the runtime: the test build's keeper
  of runners for a machine without `cyfr-locus`, named by the test
  build's configuration alone (`Locus.Runtime.Keeper.direct_keeper/0`).
  A runner is a long-lived process of the launcher started with
  `control: true`, with the argv and the explicit environment the pool
  gives it and nothing inherited, as this VM's own user, in a temporary
  home of its own: its control channel is its standard input and output,
  its relay a unix socket in its home, and its standard error reaches the
  runner's process as its log. It isolates nothing: a runner can read and
  signal this VM, and has this VM's network. A deployment runs the image,
  whose keeper isolates.

  This process is the janitor: every runner registers with it as it
  starts, and when the pool goes down with it, it kills every runner's
  process group, stops its stderr reader and removes its home. It signals
  only a reader it still holds live: a runner's process tells it when its
  reader ended or was stopped, so a pid the system gave another process
  since is never signalled. A runner whose owner ends without releasing it
  is ended by its own process.
  """

  @behaviour Locus.Runtime.Keeper

  use GenServer

  import Kernel, except: [send: 2]

  alias Locus.DirectLauncher

  @impl Locus.Runtime.Keeper
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  @doc "Start the janitor. Options: `:name` (default `#{inspect(__MODULE__)}`)."
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl Locus.Runtime.Keeper
  def available(false = _inherited?, _opts), do: :ok

  def available(true = _inherited?, _opts) do
    {:error,
     "a keeper channel was inherited (#{Locus.Keeper.channel_env()}); only cyfr-locus may " <>
       "start runners here"}
  end

  @impl Locus.Runtime.Keeper
  def spawn(%{argv: argv, env: env}) do
    spec = %{argv: argv, env: env, pool: "runner", control: true}

    case DirectLauncher.spawn([janitor: __MODULE__], spec) do
      {:ok, handle} -> {:ok, handle, []}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Locus.Runtime.Keeper
  def handle_message(%{ref: ref} = channel, {DirectLauncher, ref, event}),
    do: {:events, [Locus.Runtime.Keeper.event(event)], channel}

  def handle_message(_channel, _message), do: :unknown

  @impl Locus.Runtime.Keeper
  def send(channel, data) do
    case DirectLauncher.send_control(channel, data) do
      {:error, :unknown_spawn} -> {:error, :unknown_runner}
      answer -> answer
    end
  end

  @impl Locus.Runtime.Keeper
  def send_relay(channel, data), do: DirectLauncher.send_relay(channel, data)

  @impl Locus.Runtime.Keeper
  def close_relay(channel), do: DirectLauncher.close_relay(channel)

  @impl Locus.Runtime.Keeper
  def release(channel, grace_ms) when is_integer(grace_ms) and grace_ms >= 0,
    do: DirectLauncher.release([], channel, grace_ms)

  # A plain child process gets no cgroup of its own, so no bound.
  @impl Locus.Runtime.Keeper
  def memory_bytes(_opts), do: nil

  # A spawn fails here only when its home or its janitor cannot be had.
  @impl Locus.Runtime.Keeper
  def refusal(_reason),
    do: %{reason: "spawn_failed", message: "a runner could not be started on this machine"}

  # ---------------------------------------------------------------------------
  # The janitor
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(_opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{runners: %{}}}
  end

  @impl GenServer
  def handle_call({:watch, child, os_pid, reader_os_pid, home, wake}, _from, state) do
    entry = %{
      monitor: Process.monitor(child),
      os_pid: os_pid,
      reader_os_pid: reader_os_pid,
      home: home,
      wake: wake
    }

    {:reply, :ok, %{state | runners: Map.put(state.runners, child, entry)}}
  end

  @impl GenServer
  def handle_cast({:reader_gone, child}, state) do
    case state.runners do
      %{^child => entry} ->
        runners = Map.put(state.runners, child, %{entry | reader_os_pid: nil})
        {:noreply, %{state | runners: runners}}

      _ ->
        {:noreply, state}
    end
  end

  # A runner's process is gone, and with it the runner: it ended it.
  @impl GenServer
  def handle_info({:DOWN, monitor, :process, child, _reason}, state) do
    case state.runners do
      %{^child => %{monitor: ^monitor}} ->
        {:noreply, %{state | runners: Map.delete(state.runners, child)}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(message, state) do
    Prima.LoggerContext.unexpected(__MODULE__, message)
    {:noreply, state}
  end

  # The pool goes down: every runner still held is ended here, whatever
  # its own process is doing, and that process with it.
  @impl GenServer
  def terminate(_reason, state) do
    for {child, entry} <- state.runners do
      DirectLauncher.signal_group(entry.os_pid, "KILL")
      DirectLauncher.stop_reader(nil, entry.reader_os_pid)
      DirectLauncher.remove_home(entry.home, entry.wake)
      Process.exit(child, :kill)
    end

    :ok
  end
end
