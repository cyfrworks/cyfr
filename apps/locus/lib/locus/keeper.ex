# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Keeper do
  @moduledoc """
  The one client of cyfr-locus (`apps/locus/keeper`): every role of a
  Locus node spawns through it. A build runs through it as the executor
  (`run/2`), a backend as a long-lived spawn (`Locus.Launcher`), and a
  runner of the runtime as a long-lived spawn with a control channel and
  a relay (`spawn/2` with `control: true`), which the runtime's adapter
  (`Locus.Runtime.Keeper.Channel`) asks for.

  ## arca:bypass-ok=D — entire module

  The only paths touched are the channel's `/proc/self/fd` link and the
  attach socket in this node's private directory.

  ## The channel

  cyfr-locus starts this node with a socketpair on fd 3 and
  `KEEPER_CHANNEL` naming the socket (`socket:[inode]`);
  `channel_inherited?/0` holds fd 3 to that name, so a descriptor the
  runtime opened for itself is never taken for the channel. This server
  owns the channel, whose messages are JSON objects one per line, and the
  attach socket every spawn's relay connects to; `Prima.KeeperProtocol`
  writes and reads every byte of both.

  ## A run

  `run/2` asks for a spawn in the pool `build`, and every spawn it asks for
  carries `memory_bytes`, the builder's bound (`Locus.Config.memory_bytes/0`):
  a build is never run without one. cyfr-locus runs the command under a
  pooled uid with a 0700 home, `TMPDIR` inside it, an environment built
  from nothing but the command's `env`, resource limits, and a cgroup of
  its own holding the bound. The spawn's relay, running as this node's
  user, connects to the attach socket, presents the spawn's token and then
  carries stdin, stdout and stderr as frames: a stream byte (0 stdin, 1
  stdout, 2 stderr, 3 attach), a 4-byte big-endian length and the payload,
  a zero-length frame ending its stream. The connection goes to the
  caller, which reads its frames itself. When the command's leader exits,
  or on `release`, cyfr-locus kills every process of the uid and removes
  everything the uid left, then reports `released`; `run/2` answers only
  after that report, so no process of a build outlives the call. A
  deadline passed, a stdout bound exceeded or a cancel
  (`Locus.Executor.cancel/1`) releases the spawn with no grace. A caller
  that dies has its spawn released at once.

  ## A long-lived spawn

  `spawn/2` (`Locus.Launcher`) asks for a spawn in the pool its spec names,
  under the spec's `memory_bytes` where it names one, and answers its
  handle once cyfr-locus reports it spawned, or the refusal. The caller
  is its owner: this server holds the spawn's relay connection and sends
  the owner `{Locus.Keeper, ref, event}` for the relay attached, each
  stdout and stderr frame, the leader's exit and the uid's retirement,
  the last. `send/2` writes stdin frames through the connection, holding
  them until the relay attaches; `signal/2` signals the spawn; `release/3`
  asks for its retirement with a grace; `pool_stats/2` reads a pool. A
  relay that has not attached within 10 s, or that sends a frame the
  codec refuses or on a stream other than stdout and stderr, has its
  spawn released with no grace, and an owner that dies has its spawn
  released at once. When the channel closes every spawn is already
  retired, and every owner hears `:released`.

  ## A spawn with a control channel

  A spec with `control: true` asks for a spawn whose fd 3 is a control
  channel, carried on the relay as stream 4, and, with `isolation:
  "netns"`, whose fd 4 is its relay (`Prima.RunnerRelay`), carried as
  stream 5, in a network namespace of its own: a runner of the runtime.
  It is answered `{:ok, handle}` as soon as its request is written, with
  no spawn id, uid or pid yet, since a runner is handed out while it is
  still being staged. Its owner then hears `{:spawned, spawn_id, uid,
  pid}` or `{:refused, code}`, `:attached`, `{:control, bytes}` and
  `:control_closed` (once), `{:relay, bytes}` and `:relay_closed` (once),
  `{:stdout, bytes}` and `{:stderr, bytes}`, `{:exited, exit,
  memory_exceeded}`, `{:error, :relay_protocol}`, `{:error, :channel_lost}`
  and `:released`.

  `send_control/2` writes control bytes, holding them until the relay
  attaches; once it attaches they are written first, then the zero-length
  relay frame that opens the relay stream and ends nothing (the keeper
  sends nothing on the stream before it). `send_relay/2` writes relay
  bytes from any process while the stream is open, and `close_relay/1`
  ends it with a zero-length frame. A frame the codec refuses, or one on
  stdin or the attach stream, closes the connection: the owner hears the
  control channel and the relay closed, then `{:error, :relay_protocol}`,
  and releasing the spawn is the owner's. A spawn of this kind has no
  attach bound, and an owner that dies has it released at once.

  ## Back-pressure

  One server serves every spawn on the node, so no connection it holds
  may hold it: each is written under a 5 s bound and closed when a write
  does not finish within it. Stdin of a long-lived spawn that stops
  reading answers `{:error, :stdin_closed}`; a control or relay write
  answers the socket's error, and the owner hears the control channel and
  the relay closed. A failed write never drops what the connection
  already carried: the frames received for it before the failure reach
  the owner first.

  ## The memory bound

  A spawn that cannot stay under its bound loses every process at once,
  and the leader's `exited` says so (`memory_exceeded`), read by cyfr-locus
  from the cgroup's own counters: `run/2` then answers
  `{:error, {:memory, limit_bytes}}`, the build wire's `memory` refusal,
  whatever else this side was doing when it heard. An `exited` that does
  not say so is a status or a signal like any other, a kill for the
  container's own limit among them. Where cyfr-locus cannot give a spawn
  such a cgroup it refuses the request as `memory_unavailable`, and `run/2`
  answers the wire's `unavailable` refusal naming what the deployment
  lacks: the builder's container needs the `writable-cgroups=true`
  security option (Docker Engine 28 or later on a cgroup v2 host). No
  build runs unbounded instead.

  ## What leaves this client

  A spawn's argv and environment, its stdin, control and relay bytes, the
  frames a relay sent that are not yet whole and the attach tokens are
  shown by no status and no crash report beyond their size. A call that
  fails answers what failed, by its kind alone: the reason an exit
  carries holds the request, and a spawn's request holds its environment.

  When the channel closes, cyfr-locus has already retired every spawn and
  is exiting; this server stops, and every role it serves with it.
  """

  use GenServer

  require Logger

  @behaviour Locus.Executor
  @behaviour Locus.Launcher

  import Kernel, except: [send: 2]

  alias Locus.Executor.Log
  alias Prima.KeeperProtocol

  @channel_fd 3
  @channel_env "KEEPER_CHANNEL"
  @pool "build"
  @attach_dir "/run/locus"

  # The bytes of a relay's attach frame: its header, an empty frame's
  # length, and the spawn's token.
  @attach_frame_bytes IO.iodata_length(KeeperProtocol.end_frame(:attach)) +
                        KeeperProtocol.token_hex_bytes()

  # cyfr-locus bounds a stage and a relay's dial at 10 s each.
  @start_timeout_ms 15_000
  @attach_timeout_ms 10_000
  # Retirement after a release: its grace, the kill loop, the wait for the
  # uid's last zombies and the search for what it left.
  @release_timeout_ms 60_000
  # A relay has ended by the time `released` is sent; its last frames are
  # already on the socket.
  @drain_timeout_ms 5_000
  @channel_send_timeout_ms 30_000
  @pool_timeout_ms 5_000
  # A relay that stops reading must not hold this server: a write it has
  # not taken within the bound closes its connection.
  @relay_send_timeout_ms 5_000

  @memory_unavailable "cyfr-locus cannot bound a build's memory in this container, so it " <>
                        "runs none: start the builder with the security option " <>
                        "writable-cgroups=true (Docker Engine 28 or later on a cgroup v2 host)"

  @doc false
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  @doc """
  Starts the client. Options: `:channel`, a connected `:socket` to use in
  place of fd 3; `:attach_dir`, a directory only this node's user can
  enter (default `#{@attach_dir}`); `:name`.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The environment variable cyfr-locus names the inherited channel in."
  @spec channel_env() :: String.t()
  def channel_env, do: @channel_env

  @doc "Whether fd 3 is the channel cyfr-locus handed this node."
  @spec channel_inherited?() :: boolean()
  def channel_inherited?, do: channel_inherited?(&System.get_env/1, &File.read_link/1)

  @doc """
  `channel_inherited?/0` over `getenv`, which reads a variable as
  `System.get_env/1` does, and `readlink`, which reads a link as
  `File.read_link/1` does: `KEEPER_CHANNEL` is set and not empty, and
  `/proc/self/fd/3` links to exactly what it names.
  """
  @spec channel_inherited?(
          (String.t() -> String.t() | nil),
          (Path.t() -> {:ok, String.t()} | {:error, term()})
        ) :: boolean()
  def channel_inherited?(getenv, readlink)
      when is_function(getenv, 1) and is_function(readlink, 1) do
    with expected when is_binary(expected) and expected != "" <- getenv.(@channel_env),
         {:ok, link} <- readlink.("/proc/self/fd/#{@channel_fd}") do
      link == expected
    else
      _ -> false
    end
  end

  @doc "Whether the client is running."
  @spec running?(GenServer.server()) :: boolean()
  def running?(server \\ __MODULE__), do: GenServer.whereis(server) != nil

  @impl Locus.Executor
  def run(command, opts), do: run(__MODULE__, command, opts)

  @doc """
  `run/2` through the client `server`. Beside the executor's options,
  `:memory_bytes` names the spawn's bound in place of the builder's
  setting; there is no way to ask for none.
  """
  @spec run(
          GenServer.server(),
          Locus.Executor.command(),
          [{:memory_bytes, pos_integer()} | {atom(), term()}]
        ) ::
          {:ok, Locus.Executor.outcome()} | {:error, Locus.Executor.error()}
  def run(server, %{argv: argv, env: env, stdin: stdin}, opts) do
    memory_bytes = memory_bytes!(opts)
    monitor = Process.monitor(server)

    try do
      case GenServer.call(server, {:spawn, argv, env, memory_bytes}, @start_timeout_ms) do
        {:ok, ref} ->
          await(%{
            phase: :running,
            server: server,
            ref: ref,
            monitor: monitor,
            deadline: now() + Keyword.fetch!(opts, :timeout_ms),
            attach_by: now() + @start_timeout_ms + @attach_timeout_ms,
            released_by: nil,
            on_output: Keyword.get(opts, :on_output, fn _line -> :ok end),
            max_stdout: Keyword.fetch!(opts, :max_stdout_bytes),
            memory_bytes: memory_bytes,
            memory_exceeded: false,
            stdin: stdin,
            conn: nil,
            conn_open: false,
            frames: "",
            stdout: [],
            stdout_bytes: 0,
            log: Log.new(),
            exit: nil,
            released: false,
            failure: nil
          })

        {:error, reason} ->
          {:error, reason}
      end
    catch
      :exit, reason -> {:error, {:spawn_failed, {:keeper_unavailable, exit_kind(reason)}}}
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  # The bound is the builder's setting; a caller may name another, never
  # none, so no spawn leaves here without one.
  defp memory_bytes!(opts) do
    case Keyword.get_lazy(opts, :memory_bytes, &Locus.Config.memory_bytes/0) do
      bytes when is_integer(bytes) and bytes > 0 ->
        bytes

      other ->
        raise ArgumentError,
              "a build's memory bound is a count of bytes, got: #{Prima.LoggerContext.shape(other)}"
    end
  end

  # ————— a long-lived spawn —————

  @impl Locus.Launcher
  def spawn(server, %{argv: argv, env: env, pool: pool} = spec) do
    ref = make_ref()

    opts = %{
      pool: pool,
      memory_bytes: Map.get(spec, :memory_bytes),
      control: Map.get(spec, :control, false) == true,
      isolation: Map.get(spec, :isolation)
    }

    try do
      GenServer.call(server, {:spawn_handle, ref, argv, env, opts}, @start_timeout_ms)
    catch
      :exit, reason ->
        # A spawn this server may yet start is not left without an owner.
        GenServer.cast(server, {:abandon, ref})
        {:error, {:launcher_unavailable, exit_kind(reason)}}
    end
  end

  @impl Locus.Launcher
  def send(%{ref: ref, server: server}, data) do
    GenServer.call(server, {:stdin, ref, IO.iodata_to_binary(data)}, @channel_send_timeout_ms)
  catch
    :exit, reason -> {:error, {:launcher_unavailable, exit_kind(reason)}}
  end

  @doc """
  Write `data` to the control channel of a spawn asked for with
  `control: true`, holding it until the relay attaches.
  """
  @impl Locus.Launcher
  def send_control(%{ref: ref, server: server}, data) do
    GenServer.call(server, {:control, ref, IO.iodata_to_binary(data)}, @channel_send_timeout_ms)
  catch
    :exit, reason -> {:error, {:launcher_unavailable, exit_kind(reason)}}
  end

  @doc """
  Write `data` to the relay stream of a spawn with a control channel,
  from any process; `{:error, :relay_closed}` while the stream is not
  open. No data writes nothing, since a zero-length frame would end it.
  """
  @impl Locus.Launcher
  def send_relay(%{ref: ref, server: server}, data) do
    GenServer.call(server, {:relay, ref, IO.iodata_to_binary(data)}, @channel_send_timeout_ms)
  catch
    :exit, reason -> {:error, {:launcher_unavailable, exit_kind(reason)}}
  end

  @doc "End the relay stream of a spawn with a control channel: nothing more is written to it."
  @impl Locus.Launcher
  def close_relay(%{ref: ref, server: server}), do: GenServer.cast(server, {:close_relay, ref})

  @impl Locus.Launcher
  def signal(%{ref: ref, server: server}, sig) when is_binary(sig) do
    GenServer.call(server, {:signal, ref, sig}, @channel_send_timeout_ms)
  catch
    :exit, reason -> {:error, {:launcher_unavailable, exit_kind(reason)}}
  end

  @impl Locus.Launcher
  def release(server, %{ref: ref}, grace_ms) when is_integer(grace_ms) and grace_ms >= 0 do
    GenServer.cast(server, {:release, ref, grace_ms})
  end

  @impl Locus.Launcher
  def pool_stats(server, pool) when is_binary(pool) do
    GenServer.call(server, {:pool, pool}, @pool_timeout_ms)
  catch
    :exit, reason -> {:error, {:launcher_unavailable, exit_kind(reason)}}
  end

  @doc """
  What stopped a call, by its kind alone: the reason a call's exit
  carries holds its request, and a spawn's request holds its environment,
  so no answer of this client, or of a caller of it, carries more.
  """
  @spec exit_kind(term()) :: atom()
  def exit_kind({:timeout, _call}), do: :timeout
  def exit_kind({:noproc, _call}), do: :noproc
  def exit_kind({reason, _call}) when is_atom(reason), do: reason
  def exit_kind(_reason), do: :down

  # What ended the client under a run, by its kind alone: a crash's reason
  # may carry the client's state.
  defp down_kind(reason) when is_atom(reason), do: reason
  defp down_kind({:shutdown, _detail}), do: :shutdown
  defp down_kind(_reason), do: :crashed

  # ————— the caller's side of one run —————

  defp await(%{phase: :done} = s), do: finish(s)

  defp await(s) do
    receive do
      {__MODULE__, ref, message} when ref == s.ref ->
        s |> on_keeper(message) |> advance() |> await()

      {:tcp, conn, data} when conn == s.conn ->
        s |> on_frames(data) |> reactivate() |> advance() |> await()

      {:tcp_closed, conn} when conn == s.conn ->
        %{s | conn_open: false} |> advance() |> await()

      {:tcp_error, conn, _reason} when conn == s.conn ->
        :gen_tcp.close(conn)
        %{s | conn_open: false} |> advance() |> await()

      {:DOWN, monitor, :process, _pid, reason} when monitor == s.monitor ->
        finish(%{
          s
          | phase: :done,
            failure: s.failure || {:spawn_failed, {:keeper_down, down_kind(reason)}}
        })

      {Locus.Executor, :cancel} ->
        s |> stop(:cancelled) |> advance() |> await()
    after
      wait_ms(s) ->
        s |> on_wait_expired() |> advance() |> await()
    end
  end

  defp on_keeper(s, {:spawned, _uid, _pid}), do: s

  defp on_keeper(s, {:attached, conn}) do
    feed_stdin(conn, s.stdin)
    reactivate(%{s | conn: conn, conn_open: true})
  end

  defp on_keeper(s, {:exited, exit, memory_exceeded}),
    do: %{s | exit: exit, memory_exceeded: memory_exceeded}

  defp on_keeper(s, :released), do: %{s | released: true, released_by: now() + @drain_timeout_ms}

  defp on_keeper(s, {:error, "capacity"}), do: %{s | phase: :done, failure: :capacity}

  defp on_keeper(s, {:error, "memory_unavailable"}),
    do: %{s | phase: :done, failure: {:unavailable, @memory_unavailable}}

  defp on_keeper(s, {:error, reason}), do: %{s | phase: :done, failure: {:spawn_failed, reason}}

  # Stdin is written from a process of its own, so a command slow to read
  # it never stops this one reading its output.
  defp feed_stdin(conn, stdin) do
    frames = [
      KeeperProtocol.frames(:stdin, IO.iodata_to_binary(stdin)),
      KeeperProtocol.end_frame(:stdin)
    ]

    Kernel.spawn(fn -> :gen_tcp.send(conn, frames) end)
  end

  # A relay carries the command's stdout and stderr; a frame on any other
  # stream, or one the codec refuses, is its fault.
  defp on_frames(s, data) do
    case KeeperProtocol.parse_frames(s.frames <> data) do
      {:ok, frames, rest} -> each_frame(%{s | frames: rest}, frames)
      {:error, _reason} -> relay_fault(s)
    end
  end

  # A relay fault ends the frames after it.
  defp each_frame(s, []), do: s

  defp each_frame(s, [{stream, payload} | frames]) do
    case on_frame(s, stream, payload) do
      {:fault, s} -> s
      s -> each_frame(s, frames)
    end
  end

  defp on_frame(s, :stdout, ""), do: s
  defp on_frame(s, :stderr, ""), do: s

  defp on_frame(%{failure: nil} = s, :stdout, payload) do
    bytes = s.stdout_bytes + byte_size(payload)

    if bytes > s.max_stdout,
      do: stop(%{s | stdout: []}, {:output_too_large, s.max_stdout}),
      else: %{s | stdout: [s.stdout, payload], stdout_bytes: bytes}
  end

  defp on_frame(s, :stdout, _payload), do: s

  defp on_frame(s, :stderr, payload),
    do: %{s | log: Log.add(s.log, payload, s.on_output)}

  defp on_frame(s, _stream, _payload), do: {:fault, relay_fault(s)}

  defp relay_fault(s) do
    if s.conn, do: :gen_tcp.close(s.conn)
    %{s | frames: "", conn_open: false} |> stop({:spawn_failed, :relay_protocol})
  end

  defp reactivate(%{conn_open: true, conn: conn} = s) do
    case :inet.setopts(conn, active: :once) do
      :ok -> s
      {:error, _} -> %{s | conn_open: false}
    end
  end

  defp reactivate(s), do: s

  # The run is over once the uid is retired and the relay's connection has
  # delivered its last frame and closed; a leader that exited is retired by
  # cyfr-locus without a request. The relay has ended before `released` is
  # sent, but its connection can reach this process after that report, so
  # until the drain bound a missing connection is waited for.
  defp advance(%{phase: :done} = s), do: s

  defp advance(%{released: true, conn: conn, conn_open: false} = s) when conn != nil,
    do: %{s | phase: :done}

  defp advance(%{released: true} = s), do: s

  defp advance(%{phase: :running, exit: exit} = s) when exit != nil,
    do: %{s | phase: :releasing, released_by: now() + @release_timeout_ms}

  defp advance(s), do: s

  defp stop(%{failure: nil} = s, failure) do
    GenServer.cast(s.server, {:release, s.ref, 0})
    %{s | failure: failure, phase: :releasing, released_by: now() + @release_timeout_ms}
  end

  defp stop(s, _failure), do: s

  defp wait_ms(%{phase: :running} = s) do
    until = if s.conn, do: s.deadline, else: min(s.deadline, s.attach_by)
    max(until - now(), 0)
  end

  defp wait_ms(s), do: max(s.released_by - now(), 0)

  defp on_wait_expired(%{phase: :running} = s) do
    if s.conn == nil and now() >= s.attach_by and now() < s.deadline,
      do: stop(s, {:spawn_failed, :attach_timeout}),
      else: stop(s, :timeout)
  end

  defp on_wait_expired(s) do
    unless s.released do
      Logger.warning(
        "[Locus.Keeper] a build's uid was not reported retired within #{@release_timeout_ms} ms"
      )
    end

    %{s | phase: :done}
  end

  defp finish(s) do
    if s.conn, do: :gen_tcp.close(s.conn)
    GenServer.cast(s.server, {:done, s.ref})
    :ok = Log.finish(s.log, s.on_output)

    # The kernel's own report of how the build ended comes first: a build
    # ended at its bound is that, whatever this side was doing when it heard.
    cond do
      s.memory_exceeded -> {:error, {:memory, s.memory_bytes}}
      s.failure != nil -> {:error, s.failure}
      s.exit == nil -> {:error, {:spawn_failed, :no_exit_reported}}
      true -> {:ok, %{exit: s.exit, stdout: IO.iodata_to_binary(s.stdout)}}
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  # ————— the server —————

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    with {:ok, channel} <- open_channel(opts),
         {:ok, listener, path} <- listen(Keyword.get(opts, :attach_dir, @attach_dir)) do
      server = self()

      {:ok,
       %{
         channel: channel,
         listener: listener,
         attach_path: path,
         reader: spawn_link(fn -> read_channel(channel, server) end),
         acceptor: spawn_link(fn -> accept(listener, server) end),
         buffer: "",
         next_id: 0,
         requests: %{},
         ids: %{},
         spawns: %{},
         tokens: %{},
         conns: %{},
         pools: %{}
       }}
    else
      {:error, reason} -> {:stop, {:keeper_unavailable, reason}}
    end
  end

  defp open_channel(opts) do
    case Keyword.fetch(opts, :channel) do
      {:ok, channel} -> {:ok, channel}
      :error -> :socket.open(@channel_fd)
    end
  end

  defp listen(dir) do
    path = Path.join(dir, "attach.sock")

    with {:ok, %File.Stat{type: :directory, mode: mode}} <- File.lstat(dir),
         :ok <- private(mode, dir),
         :ok <- remove_stale(path),
         {:ok, listener} <-
           :gen_tcp.listen(0, [
             :binary,
             packet: :raw,
             active: false,
             backlog: 64,
             ifaddr: {:local, path}
           ]) do
      {:ok, listener, path}
    else
      {:ok, %File.Stat{}} -> {:error, {:attach_dir_not_a_directory, dir}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp private(mode, dir) do
    if Bitwise.band(mode, 0o077) == 0, do: :ok, else: {:error, {:attach_dir_not_private, dir}}
  end

  defp remove_stale(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:attach_socket, reason}}
    end
  end

  defp read_channel(channel, server) do
    case :socket.recv(channel, 0, :infinity) do
      {:ok, data} ->
        Kernel.send(server, {:channel, data})
        read_channel(channel, server)

      {:error, reason} ->
        Kernel.send(server, {:channel_closed, reason})
    end
  end

  defp accept(listener, server) do
    case :gen_tcp.accept(listener) do
      {:ok, conn} ->
        handshake = Kernel.spawn(fn -> receive(do: (:go -> handshake(conn, server))) end)

        case :gen_tcp.controlling_process(conn, handshake) do
          :ok -> Kernel.send(handshake, :go)
          {:error, _} -> :gen_tcp.close(conn)
        end

        accept(listener, server)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        Process.sleep(100)
        accept(listener, server)
    end
  end

  # A relay's first frame is its spawn's token; the connection goes to the
  # process that reads its frames: a run's caller, or this server for a
  # long-lived spawn.
  defp handshake(conn, server) do
    with {:ok, frame} <- :gen_tcp.recv(conn, @attach_frame_bytes, @attach_timeout_ms),
         {:ok, token} <- KeeperProtocol.decode_attach(frame),
         {:ok, reader, ref} <- GenServer.call(server, {:attach, token}),
         :ok <- :gen_tcp.controlling_process(conn, reader) do
      Kernel.send(reader, {__MODULE__, ref, {:attached, conn}})
    else
      _ -> :gen_tcp.close(conn)
    end
  catch
    :exit, _ -> :gen_tcp.close(conn)
  end

  @impl GenServer
  def handle_call({:spawn, argv, env, memory_bytes}, {owner, _tag}, state) do
    request = %{pool: @pool, argv: argv, env: env, memory_bytes: memory_bytes}

    case start_spawn(state, request, %{kind: :run, owner: owner, from: nil}) do
      {:ok, ref, state} ->
        {:reply, {:ok, ref}, state}

      {:error, :unencodable} ->
        {:reply, {:error, {:spawn_failed, :unencodable_command}}, state}

      {:error, reason} ->
        {:stop, {:shutdown, {:channel_lost, reason}}, {:error, {:spawn_failed, :channel_lost}},
         state}
    end
  end

  def handle_call({:spawn_handle, ref, argv, env, opts}, {owner, _tag} = from, state) do
    request =
      %{pool: opts.pool, argv: argv, env: env}
      |> put_given(:memory_bytes, opts.memory_bytes)
      |> put_given(:isolation, opts.isolation)
      |> put_given(:control, opts.control || nil)

    # A spawn with a control channel is answered once its request is
    # written; a long-lived spawn once cyfr-locus reports it spawned.
    control? = opts.control

    extra =
      if control?,
        do: %{kind: :control, owner: owner, from: nil, ref: ref},
        else: %{kind: :handle, owner: owner, from: from, ref: ref}

    case start_spawn(state, request, extra) do
      {:ok, ref, state} when control? ->
        {:reply, {:ok, handle(ref, nil, nil, nil)}, state}

      {:ok, _ref, state} ->
        {:noreply, state}

      {:error, :unencodable} ->
        {:reply, {:error, {:spawn_failed, :unencodable_command}}, state}

      {:error, reason} ->
        {:stop, {:shutdown, {:channel_lost, reason}},
         {:error, {:launcher_unavailable, :channel_lost}}, state}
    end
  end

  def handle_call({:attach, token}, _from, state) do
    {ref, tokens} = Map.pop(state.tokens, token)
    state = %{state | tokens: tokens}

    case ref && state.requests[ref] do
      %{kind: :run, owner: owner} when is_pid(owner) ->
        {:reply, {:ok, owner, ref}, state}

      %{kind: kind, owner: owner} when kind in [:handle, :control] and is_pid(owner) ->
        {:reply, {:ok, self(), ref}, state}

      _ ->
        {:reply, :error, state}
    end
  end

  def handle_call({:stdin, ref, data}, _from, state) do
    case state.requests[ref] do
      %{kind: :handle, released: false, conn: nil, attached: false} = entry ->
        {:reply, :ok, put_entry(state, ref, %{entry | pending: [entry.pending, data]})}

      %{kind: :handle, released: false, conn: conn} when conn != nil ->
        {:reply, write_stdin(conn, data), state}

      _ ->
        {:reply, {:error, :unknown_spawn}, state}
    end
  end

  def handle_call({:control, ref, data}, _from, state) do
    case state.requests[ref] do
      %{kind: :control, conn: nil, attached: false} = entry ->
        {:reply, :ok, put_entry(state, ref, %{entry | pending: [entry.pending, data]})}

      %{kind: :control, conn: conn} when conn != nil ->
        write_held(state, conn, KeeperProtocol.frames(:control, data))

      %{kind: :control} ->
        {:reply, {:error, :control_closed}, state}

      _ ->
        {:reply, {:error, :unknown_spawn}, state}
    end
  end

  # An empty write would end the stream.
  def handle_call({:relay, _ref, ""}, _from, state), do: {:reply, :ok, state}

  def handle_call({:relay, ref, data}, _from, state) do
    case state.requests[ref] do
      %{kind: :control, conn: conn, relay_open: true} when conn != nil ->
        write_held(state, conn, KeeperProtocol.frames(:relay, data))

      _closed ->
        {:reply, {:error, :relay_closed}, state}
    end
  end

  def handle_call({:signal, ref, sig}, _from, state) do
    with %{kind: :handle, released: false, spawn_id: spawn_id} when spawn_id != nil <-
           state.requests[ref],
         {:ok, line} <- encode(%{type: :signal, spawn_id: spawn_id, sig: sig}) do
      case send_line(state, line) do
        :ok ->
          {:reply, :ok, state}

        {:error, reason} ->
          {:stop, {:shutdown, {:channel_lost, reason}},
           {:error, {:launcher_unavailable, :channel_lost}}, state}
      end
    else
      {:error, :unencodable} -> {:reply, {:error, :unencodable}, state}
      _ -> {:reply, {:error, :unknown_spawn}, state}
    end
  end

  def handle_call({:pool, pool}, from, state) do
    id = "pool-" <> Integer.to_string(state.next_id + 1)

    with {:ok, line} <- encode(%{type: :pool, id: id, pool: pool}),
         :ok <- send_line(state, line) do
      {:noreply, %{state | next_id: state.next_id + 1, pools: Map.put(state.pools, id, from)}}
    else
      {:error, :unencodable} ->
        {:reply, {:error, :unencodable}, state}

      {:error, reason} ->
        {:stop, {:shutdown, {:channel_lost, reason}},
         {:error, {:launcher_unavailable, :channel_lost}}, state}
    end
  end

  @impl GenServer
  def handle_cast({:release, ref, grace_ms}, state),
    do: {:noreply, release_spawn(state, ref, grace_ms)}

  def handle_cast({:close_relay, ref}, state) do
    case state.requests[ref] do
      %{kind: :control, conn: conn, relay_open: true} = entry when conn != nil ->
        state = put_entry(state, ref, %{entry | relay_open: false})

        case write(conn, KeeperProtocol.end_frame(:relay)) do
          :ok -> {:noreply, state}
          {:error, _reason} -> {:noreply, write_failed(state, conn)}
        end

      _closed ->
        {:noreply, state}
    end
  end

  # The caller's run is over. A spawn not yet reported retired is released
  # and forgotten once it is.
  def handle_cast({:done, ref}, state) do
    case state.requests[ref] do
      nil -> {:noreply, state}
      entry -> {:noreply, abandon(state, ref, entry)}
    end
  end

  # A long-lived spawn whose caller stopped waiting for it.
  def handle_cast({:abandon, ref}, state) do
    case state.requests[ref] do
      nil -> {:noreply, state}
      entry -> {:noreply, abandon(state, ref, entry)}
    end
  end

  @impl GenServer
  def handle_info({:channel, data}, state) do
    case KeeperProtocol.split_lines(state.buffer, data) do
      {:error, :line_too_long} ->
        Logger.error(
          "[Locus.Keeper] FATAL: the keeper sent a line longer than " <>
            "#{KeeperProtocol.max_line_bytes()} bytes"
        )

        {:stop, {:shutdown, :channel_fault}, state}

      {lines, rest} ->
        {:noreply, Enum.reduce(lines, %{state | buffer: rest}, &on_line/2)}
    end
  end

  # cyfr-locus retires every spawn before its channel closes: a run's
  # caller and a control spawn's owner hear the channel lost, a long-lived
  # spawn's owner its release.
  def handle_info({:channel_closed, reason}, state) do
    Logger.error(
      "[Locus.Keeper] FATAL: the keeper channel closed (#{inspect(reason)}); " <>
        "every spawn of this node stops"
    )

    for {ref, entry} <- state.requests do
      case entry do
        %{kind: :handle, from: from} when from != nil ->
          GenServer.reply(from, {:error, {:launcher_unavailable, :channel_lost}})

        %{kind: :handle} ->
          notify(entry, ref, :released)

        _run_or_control ->
          notify(entry, ref, {:error, :channel_lost})
      end
    end

    for {_id, from} <- state.pools,
        do: GenServer.reply(from, {:error, {:launcher_unavailable, :channel_lost}})

    {:stop, {:shutdown, :channel_lost}, state}
  end

  def handle_info({__MODULE__, ref, {:attached, conn}}, state) do
    case state.requests[ref] do
      %{kind: :handle, conn: nil, attached: false, released: false} = entry ->
        {:noreply, attached(state, ref, entry, conn)}

      %{kind: :control, conn: nil, attached: false} = entry ->
        {:noreply, control_attached(state, ref, entry, conn)}

      _ ->
        :gen_tcp.close(conn)
        {:noreply, state}
    end
  end

  def handle_info({:tcp, conn, data}, state) do
    case state.conns[conn] do
      nil ->
        :gen_tcp.close(conn)
        {:noreply, state}

      ref ->
        {:noreply, on_held_frames(state, ref, conn, data)}
    end
  end

  def handle_info({:tcp_closed, conn}, state), do: {:noreply, conn_gone(state, conn)}

  def handle_info({:tcp_error, conn, _reason}, state) do
    :gen_tcp.close(conn)
    {:noreply, conn_gone(state, conn)}
  end

  # A spawned relay that never attached: the spawn is of no use to its
  # owner, and is released.
  def handle_info({:attach_timeout, ref}, state) do
    case state.requests[ref] do
      %{kind: :handle, attached: false, released: false} ->
        {:noreply, release_spawn(state, ref, 0)}

      _ ->
        {:noreply, state}
    end
  end

  # A retired spawn's relay connection, past the bound it had to deliver
  # its last frames in.
  def handle_info({:drain, ref}, state) do
    case state.requests[ref] do
      %{kind: :handle, released: true} = entry -> {:noreply, retired(state, ref, entry)}
      _ -> {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Enum.find(state.requests, fn {_ref, entry} -> entry.monitor == monitor end) do
      {ref, entry} -> {:noreply, abandon(state, ref, entry)}
      nil -> {:noreply, state}
    end
  end

  def handle_info({:EXIT, pid, reason}, %{acceptor: pid} = state),
    do: {:stop, {:shutdown, {:attach_listener_down, reason}}, state}

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(message, state) do
    Prima.LoggerContext.unexpected(__MODULE__, message)
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    :gen_tcp.close(state.listener)
    File.rm(state.attach_path)
    :ok
  end

  # An attach token admits a relay as its spawn, a spawn's request carries
  # its argv and environment, and its stdio, control and relay bytes carry
  # what its owner wrote and what it answered: an attempt's opened keys, a
  # tool's arguments and results among them. No status or crash report
  # shows more of any than its size, and the debug log, which holds them,
  # is left out.
  @impl GenServer
  def format_status(status) do
    Map.new(status, fn
      {:state, %{requests: requests} = state} ->
        {:state,
         %{
           state
           | requests: Map.new(requests, fn {ref, entry} -> {ref, redact(entry)} end),
             tokens: map_size(state.tokens)
         }}

      {:message, message} ->
        {:message, redact_message(message)}

      {:log, _log} ->
        {:log, []}

      other ->
        other
    end)
  end

  defp redact(entry) do
    %{
      entry
      | token: :redacted,
        pending: {:redacted, IO.iodata_length(entry.pending)},
        frames: {:redacted, byte_size(entry.frames)}
    }
  end

  defp redact_message({:tcp, conn, data}), do: {:tcp, conn, redacted(data)}

  defp redact_message({stream, ref, data}) when stream in [:stdin, :control, :relay],
    do: {stream, ref, redacted(data)}

  defp redact_message({:attach, _token}), do: {:attach, :redacted}

  defp redact_message({:spawn, _argv, _env, memory_bytes}),
    do: {:spawn, :redacted, :redacted, memory_bytes}

  defp redact_message({:spawn_handle, ref, _argv, _env, opts}),
    do: {:spawn_handle, ref, :redacted, :redacted, opts}

  defp redact_message(message), do: message

  defp redacted(data) when is_binary(data), do: {:redacted, byte_size(data)}
  defp redacted(_data), do: :redacted

  defp put_given(map, _key, nil), do: map
  defp put_given(map, key, value), do: Map.put(map, key, value)

  defp handle(ref, spawn_id, uid, pid),
    do: %{ref: ref, spawn_id: spawn_id, uid: uid, pid: pid, server: self()}

  # Writes a spawn request and follows it: `extra` names its kind, its
  # owner and, for a long-lived spawn, the caller its handle is answered to
  # and the ref the caller chose.
  defp start_spawn(state, request, extra) do
    id = Integer.to_string(state.next_id + 1)
    token = 32 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

    request =
      Map.merge(request, %{
        type: :spawn,
        id: id,
        attach: %{path: state.attach_path, token: token}
      })

    with {:ok, line} <- encode(request),
         :ok <- send_line(state, line) do
      ref = Map.get(extra, :ref) || make_ref()

      entry = %{
        kind: extra.kind,
        owner: extra.owner,
        from: extra.from,
        monitor: Process.monitor(extra.owner),
        id: id,
        token: token,
        spawn_id: nil,
        release_on_spawn: nil,
        release_sent: false,
        released: false,
        attached: false,
        conn: nil,
        frames: "",
        pending: [],
        control_open: extra.kind == :control,
        relay_open: false
      }

      {:ok, ref,
       %{
         state
         | next_id: state.next_id + 1,
           requests: Map.put(state.requests, ref, entry),
           ids: Map.put(state.ids, id, ref),
           tokens: Map.put(state.tokens, token, ref)
       }}
    end
  end

  defp on_line("", state), do: state

  defp on_line(line, state) do
    case KeeperProtocol.decode_reply(line) do
      {:ok, reply} ->
        on_reply(reply, state)

      {:error, reason} ->
        Logger.warning(
          "[Locus.Keeper] the keeper sent a line that is not a reply (#{inspect(reason)}); ignored"
        )

        state
    end
  end

  defp on_reply({:spawned, id, spawn_id, uid, pid}, state) do
    with_request(state, state.ids[id], fn ref, entry ->
      entry = spawned(entry, ref, spawn_id, uid, pid)
      state = %{state | spawns: Map.put(state.spawns, spawn_id, ref)}
      state = put_entry(state, ref, %{entry | spawn_id: spawn_id})

      case entry.release_on_spawn do
        nil -> state
        grace -> release_spawn(state, ref, grace)
      end
    end)
  end

  defp on_reply({:error, id, _spawn_id, code}, state) when is_binary(id) do
    case Map.pop(state.pools, id) do
      {nil, _pools} ->
        with_request(state, state.ids[id], fn ref, entry ->
          refused(entry, ref, code)
          drop(state, ref)
        end)

      {from, pools} ->
        GenServer.reply(from, {:error, {:refused, code}})
        %{state | pools: pools}
    end
  end

  # A release for a spawn cyfr-locus no longer holds: its retirement is done.
  defp on_reply({:error, nil, spawn_id, "unknown_spawn"}, state) when is_binary(spawn_id),
    do: released(state, spawn_id)

  defp on_reply({:exited, spawn_id, exit, memory_exceeded}, state) do
    with_request(state, state.spawns[spawn_id], fn ref, entry ->
      notify(entry, ref, exited(entry, exit, memory_exceeded))
      state
    end)
  end

  defp on_reply({:released, spawn_id}, state), do: released(state, spawn_id)

  defp on_reply({:pool, id, _pool, size, free, quarantined}, state) do
    case Map.pop(state.pools, id) do
      {nil, _pools} ->
        state

      {from, pools} ->
        GenServer.reply(from, {:ok, %{size: size, free: free, quarantined: quarantined}})
        %{state | pools: pools}
    end
  end

  # An `error` for a spawn this client does not follow is ignored.
  defp on_reply(_reply, state), do: state

  # A run's caller hears the spawn's uid and pid; a long-lived spawn's
  # caller is answered its handle, and the relay has its bound to attach; a
  # spawn with a control channel, answered already, has its owner hear it.
  defp spawned(%{kind: :run} = entry, ref, _spawn_id, uid, pid) do
    notify(entry, ref, {:spawned, uid, pid})
    entry
  end

  defp spawned(%{kind: :handle} = entry, ref, spawn_id, uid, pid) do
    if entry.from, do: GenServer.reply(entry.from, {:ok, handle(ref, spawn_id, uid, pid)})

    unless entry.attached,
      do: Process.send_after(self(), {:attach_timeout, ref}, @attach_timeout_ms)

    %{entry | from: nil}
  end

  defp spawned(%{kind: :control} = entry, ref, spawn_id, uid, pid) do
    notify(entry, ref, {:spawned, spawn_id, uid, pid})
    entry
  end

  defp refused(%{kind: :run} = entry, ref, code), do: notify(entry, ref, {:error, code})

  defp refused(%{kind: :handle, from: from}, _ref, code) when from != nil,
    do: GenServer.reply(from, {:error, {:refused, code}})

  defp refused(%{kind: :control} = entry, ref, code), do: notify(entry, ref, {:refused, code})

  defp refused(_entry, _ref, _code), do: :ok

  defp exited(%{kind: :run}, exit, memory_exceeded), do: {:exited, exit, memory_exceeded}

  # A long-lived spawn's owner hears the exit as `Locus.Launcher` spells it;
  # an end at the memory bound is a SIGKILL there, as the kernel sent it.
  defp exited(%{kind: :handle}, {:status, code}, _memory_exceeded), do: {:exited, code, nil}
  defp exited(%{kind: :handle}, {:signal, signal}, _memory_exceeded), do: {:exited, nil, signal}

  defp exited(%{kind: :control}, exit, memory_exceeded), do: {:exited, exit, memory_exceeded}

  # A run's entry stays until its caller is done, so a relay connection
  # that arrives after the report still reaches the caller. A long-lived
  # spawn's owner hears the release once the relay's connection has
  # delivered its last frames, or its bound passes. A spawn with a control
  # channel is done at the report.
  defp released(state, spawn_id) do
    with_request(state, state.spawns[spawn_id], fn ref, entry ->
      case entry do
        %{kind: :run} ->
          notify(entry, ref, :released)

          if entry.owner,
            do: %{
              put_entry(state, ref, %{entry | released: true})
              | spawns: Map.delete(state.spawns, spawn_id)
            },
            else: drop(state, ref)

        %{kind: :control} ->
          retired(state, ref, entry)

        %{kind: :handle, conn: nil} ->
          retired(state, ref, entry)

        %{kind: :handle} ->
          Process.send_after(self(), {:drain, ref}, @drain_timeout_ms)

          %{
            put_entry(state, ref, %{entry | released: true})
            | spawns: Map.delete(state.spawns, spawn_id)
          }
      end
    end)
  end

  defp retired(state, ref, entry) do
    notify(entry, ref, :released)
    drop(state, ref)
  end

  # ————— a held relay connection —————

  defp attached(state, ref, entry, conn) do
    pending = IO.iodata_to_binary(entry.pending)
    :ok = hold(conn)
    notify(entry, ref, :attached)
    entry = %{entry | conn: conn, attached: true, pending: []}
    state = %{put_entry(state, ref, entry) | conns: Map.put(state.conns, conn, ref)}

    case write_stdin(conn, pending) do
      :ok -> state
      {:error, _reason} -> state |> received(conn) |> relay_fault(ref, conn)
    end
  end

  # The control bytes held for the runner go first, then the zero-length
  # frame that opens the relay stream and ends nothing: the keeper sends
  # none of the runner's relay bytes before it.
  defp control_attached(state, ref, entry, conn) do
    pending = IO.iodata_to_binary(entry.pending)
    :ok = hold(conn)
    notify(entry, ref, :attached)
    entry = %{entry | conn: conn, attached: true, pending: [], relay_open: true}
    state = %{put_entry(state, ref, entry) | conns: Map.put(state.conns, conn, ref)}

    case write(conn, [KeeperProtocol.frames(:control, pending), KeeperProtocol.end_frame(:relay)]) do
      :ok -> state
      {:error, _reason} -> write_failed(state, conn)
    end
  end

  # Every connection this server holds is read as it arrives and written
  # under the bound.
  defp hold(conn) do
    :inet.setopts(conn,
      active: true,
      send_timeout: @relay_send_timeout_ms,
      send_timeout_close: true
    )
  end

  defp write(conn, iodata), do: :gen_tcp.send(conn, iodata)

  # A write to a held connection that failed, its bound among the ways:
  # the connection is closed, and its spawn's owner hears so.
  defp write_held(state, conn, iodata) do
    case write(conn, iodata) do
      :ok -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, write_failed(state, conn)}
    end
  end

  # What the connection carried before the write failed reaches the owner
  # before its close does: the frames already received for it are read, in
  # order, and only then is it closed and forgotten.
  defp write_failed(state, conn) do
    state = received(state, conn)
    :gen_tcp.close(conn)
    conn_gone(state, conn)
  end

  defp received(state, conn) do
    receive do
      {:tcp, ^conn, data} ->
        case state.conns[conn] do
          nil -> state
          ref -> state |> on_held_frames(ref, conn, data) |> received(conn)
        end
    after
      0 -> state
    end
  end

  # A zero-length frame would end the spawn's stdin, so no data sends none.
  defp write_stdin(_conn, ""), do: :ok

  defp write_stdin(conn, data) do
    case write(conn, KeeperProtocol.frames(:stdin, data)) do
      :ok -> :ok
      {:error, _reason} -> {:error, :stdin_closed}
    end
  end

  defp on_held_frames(state, ref, conn, data) do
    entry = state.requests[ref]

    case KeeperProtocol.parse_frames(entry.frames <> data) do
      {:ok, frames, rest} -> held_frames(state, ref, conn, %{entry | frames: rest}, frames)
      {:error, _reason} -> relay_fault(state, ref, conn)
    end
  end

  defp held_frames(state, ref, _conn, entry, []), do: put_entry(state, ref, entry)

  defp held_frames(state, ref, conn, entry, [{stream, payload} | frames]) do
    case held_frame(entry, ref, stream, payload) do
      {:ok, entry} -> held_frames(state, ref, conn, entry, frames)
      :fault -> relay_fault(put_entry(state, ref, entry), ref, conn)
    end
  end

  # Every held spawn's relay carries its stdout and stderr; a spawn with a
  # control channel's also carries the control stream and the relay
  # stream. A frame on any other stream is its fault.
  defp held_frame(entry, _ref, stream, "") when stream in [:stdout, :stderr], do: {:ok, entry}

  defp held_frame(entry, ref, stream, payload) when stream in [:stdout, :stderr],
    do: {:ok, notify_entry(entry, ref, {stream, payload})}

  defp held_frame(%{kind: :control, control_open: true} = entry, ref, :control, ""),
    do: {:ok, notify_entry(%{entry | control_open: false}, ref, :control_closed)}

  defp held_frame(%{kind: :control} = entry, _ref, :control, ""), do: {:ok, entry}

  defp held_frame(%{kind: :control} = entry, ref, :control, payload),
    do: {:ok, notify_entry(entry, ref, {:control, payload})}

  defp held_frame(%{kind: :control, relay_open: true} = entry, ref, :relay, ""),
    do: {:ok, notify_entry(%{entry | relay_open: false}, ref, :relay_closed)}

  defp held_frame(%{kind: :control} = entry, _ref, :relay, ""), do: {:ok, entry}

  defp held_frame(%{kind: :control} = entry, ref, :relay, payload),
    do: {:ok, notify_entry(entry, ref, {:relay, payload})}

  defp held_frame(_entry, _ref, _stream, _payload), do: :fault

  defp notify_entry(entry, ref, event) do
    notify(entry, ref, event)
    entry
  end

  # A relay at fault has its connection closed, and what follows is read
  # from the state without it. A long-lived spawn is released with no
  # grace; a spawn with a control channel's owner hears the fault after
  # the channel's and the relay's close, and releasing it is the owner's.
  defp relay_fault(state, ref, conn) do
    :gen_tcp.close(conn)
    state = conn_gone(state, conn)

    case state.requests[ref] do
      nil ->
        state

      %{kind: :control} = entry ->
        notify(entry, ref, {:error, :relay_protocol})
        state

      _held ->
        release_spawn(state, ref, 0)
    end
  end

  # The relay's connection is gone: a spawn already retired is done, and a
  # spawn with a control channel has its owner hear the channel and the
  # relay closed, each once.
  defp conn_gone(state, conn) do
    {ref, conns} = Map.pop(state.conns, conn)
    state = %{state | conns: conns}

    with_request(state, ref, fn ref, entry ->
      entry = %{entry | conn: nil, frames: ""}

      cond do
        entry.kind == :control -> put_entry(state, ref, streams_closed(entry, ref))
        entry.released -> retired(put_entry(state, ref, entry), ref, entry)
        true -> put_entry(state, ref, entry)
      end
    end)
  end

  defp streams_closed(entry, ref) do
    entry =
      if entry.control_open,
        do: notify_entry(%{entry | control_open: false}, ref, :control_closed),
        else: entry

    if entry.relay_open,
      do: notify_entry(%{entry | relay_open: false}, ref, :relay_closed),
      else: entry
  end

  # ————— the requests —————

  defp abandon(state, ref, %{released: true}), do: drop(state, ref)

  # A spawn whose release was sent already stays followed until its
  # retirement is reported.
  defp abandon(state, ref, entry) do
    state
    |> put_entry(ref, %{entry | owner: nil, from: nil})
    |> Map.update!(:tokens, &Map.delete(&1, entry.token))
    |> release_spawn(ref, 0)
  end

  defp with_request(state, nil, _fun), do: state

  defp with_request(state, ref, fun) do
    case state.requests[ref] do
      nil -> state
      entry -> fun.(ref, entry)
    end
  end

  defp put_entry(state, ref, entry), do: %{state | requests: Map.put(state.requests, ref, entry)}

  defp notify(%{owner: owner}, ref, message) when is_pid(owner),
    do: Kernel.send(owner, {__MODULE__, ref, message})

  defp notify(_entry, _ref, _message), do: :ok

  defp drop(state, ref) do
    {entry, requests} = Map.pop(state.requests, ref)
    Process.demonitor(entry.monitor, [:flush])
    if entry.conn, do: :gen_tcp.close(entry.conn)

    %{
      state
      | requests: requests,
        ids: Map.delete(state.ids, entry.id),
        spawns:
          if(entry.spawn_id, do: Map.delete(state.spawns, entry.spawn_id), else: state.spawns),
        tokens: Map.delete(state.tokens, entry.token),
        conns: if(entry.conn, do: Map.delete(state.conns, entry.conn), else: state.conns)
    }
  end

  # A release is written once: a second asks for nothing more of cyfr-locus,
  # which is retiring the uid already. One asked before cyfr-locus reported
  # the spawn follows its report, with the shortest grace asked.
  defp release_spawn(state, ref, grace_ms) do
    case state.requests[ref] do
      nil ->
        state

      %{released: true} ->
        state

      %{release_sent: true} ->
        state

      %{spawn_id: nil} = entry ->
        put_entry(state, ref, %{
          entry
          | release_on_spawn: min(entry.release_on_spawn || grace_ms, grace_ms)
        })

      %{spawn_id: spawn_id} = entry ->
        case encode(%{type: :release, spawn_id: spawn_id, grace_ms: grace_ms}) do
          {:ok, line} ->
            _ = send_line(state, line)
            put_entry(state, ref, %{entry | release_sent: true})

          # A grace past what cyfr-locus accepts, which it would refuse.
          {:error, :unencodable} ->
            Logger.error(
              "[Locus.Keeper] a spawn was not released: a grace of #{grace_ms} ms is past " <>
                "what cyfr-locus accepts"
            )

            state
        end
    end
  end

  # A request built from a command that the keeper would refuse as
  # malformed is refused here, before it is sent; the refusal never quotes
  # the command, whose environment may hold a credential.
  defp encode(request) do
    {:ok, KeeperProtocol.encode(request)}
  rescue
    ArgumentError -> {:error, :unencodable}
  end

  defp send_line(state, line), do: :socket.send(state.channel, line, @channel_send_timeout_ms)
end
