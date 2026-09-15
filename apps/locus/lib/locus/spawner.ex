# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Spawner do
  @moduledoc """
  The builder's client of cyfr-spawn (`apps/spawn`) and the executor builds
  run through where it runs.

  ## arca:bypass-ok=D — entire module

  The only paths touched are the channel's `/proc/self/fd` link and the
  attach socket in this node's private directory.

  ## The channel

  cyfr-spawn starts this node with a socketpair on fd 3 and
  `CYFR_SPAWN_CHANNEL` naming the socket (`socket:[inode]`);
  `channel_inherited?/0` holds fd 3 to that name, so a descriptor the
  runtime opened for itself is never taken for the channel. This server
  owns the channel, whose messages are JSON objects one per line (the
  protocol of `apps/spawn/internal/protocol`), and the attach socket every
  spawn's relay connects to.

  ## A run

  `run/2` asks for a spawn in the pool `build`. cyfr-spawn runs the command
  under a pooled uid with a 0700 home, `TMPDIR` inside it, an environment
  built from nothing but the command's `env`, and resource limits. The
  spawn's relay, running as this node's user, connects to the attach
  socket, presents the spawn's token and then carries stdin, stdout and
  stderr as frames: a stream byte (0 stdin, 1 stdout, 2 stderr, 3 attach),
  a 4-byte big-endian length and the payload, a zero-length frame ending
  its stream. When the command's leader exits, or on `release`, cyfr-spawn
  kills every process of the uid and removes everything the uid left, then
  reports `released`; `run/2` answers only after that report, so no
  process of a build outlives the call. A deadline passed or a stdout
  bound exceeded releases the spawn with no grace. A caller that dies has
  its spawn released at once.

  When the channel closes, cyfr-spawn has already retired every spawn and
  is exiting; this server stops, and the builder with it.
  """

  use GenServer

  require Logger

  @behaviour Locus.Executor

  alias Locus.Executor.Log

  @channel_fd 3
  @channel_env "CYFR_SPAWN_CHANNEL"
  @protocol_version 1
  @pool "build"
  @attach_dir "/run/cyfr-builder"

  @stream_stdin 0
  @stream_stdout 1
  @stream_stderr 2
  @stream_attach 3
  @max_frame_bytes 65_536
  @token_hex_bytes 64
  @max_line_bytes 1_048_576

  # cyfr-spawn bounds a stage and a relay's dial at 10 s each.
  @start_timeout_ms 15_000
  @attach_timeout_ms 10_000
  # Retirement after a release: its grace, the kill loop, the wait for the
  # uid's last zombies and the search for what it left.
  @release_timeout_ms 60_000
  # A relay has ended by the time `released` is sent; its last frames are
  # already on the socket.
  @drain_timeout_ms 5_000
  @channel_send_timeout_ms 30_000

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

  @doc "Whether fd 3 is the channel cyfr-spawn handed this node."
  @spec channel_inherited?() :: boolean()
  def channel_inherited? do
    with expected when is_binary(expected) and expected != "" <- System.get_env(@channel_env),
         {:ok, link} <- File.read_link("/proc/self/fd/#{@channel_fd}") do
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

  @doc "`run/2` through the client `server`."
  @spec run(GenServer.server(), Locus.Executor.command(), Locus.Executor.opts()) ::
          {:ok, Locus.Executor.outcome()} | {:error, Locus.Executor.error()}
  def run(server, %{argv: argv, env: env, stdin: stdin}, opts) do
    monitor = Process.monitor(server)

    try do
      case GenServer.call(server, {:spawn, argv, env}, @start_timeout_ms) do
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
      :exit, reason -> {:error, {:spawn_failed, {:spawner_unavailable, reason}}}
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  # ————— the caller's side of one run —————

  defp await(%{phase: :done} = s), do: finish(s)

  defp await(s) do
    receive do
      {__MODULE__, ref, message} when ref == s.ref ->
        s |> on_spawner(message) |> advance() |> await()

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
            failure: s.failure || {:spawn_failed, {:spawner_down, reason}}
        })
    after
      wait_ms(s) ->
        s |> on_wait_expired() |> advance() |> await()
    end
  end

  defp on_spawner(s, {:spawned, _uid, _pid}), do: s

  defp on_spawner(s, {:attached, conn}) do
    feed_stdin(conn, s.stdin)
    reactivate(%{s | conn: conn, conn_open: true})
  end

  defp on_spawner(s, {:exited, code, signal}),
    do: %{s | exit: if(signal, do: {:signal, signal}, else: {:status, code})}

  defp on_spawner(s, :released), do: %{s | released: true, released_by: now() + @drain_timeout_ms}

  defp on_spawner(s, {:error, "capacity"}), do: %{s | phase: :done, failure: :capacity}
  defp on_spawner(s, {:error, reason}), do: %{s | phase: :done, failure: {:spawn_failed, reason}}

  # Stdin is written from a process of its own, so a command slow to read
  # it never stops this one reading its output.
  defp feed_stdin(conn, stdin) do
    frames = [chunk_frames(IO.iodata_to_binary(stdin)), frame(@stream_stdin, "")]
    spawn(fn -> :gen_tcp.send(conn, frames) end)
  end

  defp chunk_frames(<<chunk::binary-size(@max_frame_bytes), rest::binary>>),
    do: [frame(@stream_stdin, chunk) | chunk_frames(rest)]

  defp chunk_frames(<<>>), do: []
  defp chunk_frames(chunk), do: [frame(@stream_stdin, chunk)]

  defp frame(stream, payload), do: [<<stream, byte_size(payload)::32>>, payload]

  defp on_frames(s, data), do: parse_frames(%{s | frames: s.frames <> data})

  defp parse_frames(%{frames: <<stream, length::32, rest::binary>>} = s)
       when byte_size(rest) >= length and length <= @max_frame_bytes do
    <<payload::binary-size(^length), rest::binary>> = rest
    %{s | frames: rest} |> on_frame(stream, payload) |> parse_frames()
  end

  defp parse_frames(%{frames: <<_stream, length::32, _::binary>>} = s)
       when length > @max_frame_bytes,
       do: relay_fault(s)

  defp parse_frames(s), do: s

  defp on_frame(s, @stream_stdout, ""), do: s
  defp on_frame(s, @stream_stderr, ""), do: s

  defp on_frame(%{failure: nil} = s, @stream_stdout, payload) do
    bytes = s.stdout_bytes + byte_size(payload)

    if bytes > s.max_stdout,
      do: stop(%{s | stdout: []}, {:output_too_large, s.max_stdout}),
      else: %{s | stdout: [s.stdout, payload], stdout_bytes: bytes}
  end

  defp on_frame(s, @stream_stdout, _payload), do: s

  defp on_frame(s, @stream_stderr, payload),
    do: %{s | log: Log.add(s.log, payload, s.on_output)}

  defp on_frame(s, _stream, _payload), do: relay_fault(s)

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
  # cyfr-spawn without a request. The relay has ended before `released` is
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
        "[Locus.Spawner] a build's uid was not reported retired within #{@release_timeout_ms} ms"
      )
    end

    %{s | phase: :done}
  end

  defp finish(s) do
    if s.conn, do: :gen_tcp.close(s.conn)
    GenServer.cast(s.server, {:done, s.ref})
    log = Log.finish(s.log, s.on_output)

    cond do
      s.failure != nil -> {:error, s.failure}
      s.exit == nil -> {:error, {:spawn_failed, :no_exit_reported}}
      true -> {:ok, %{exit: s.exit, stdout: IO.iodata_to_binary(s.stdout), log: log}}
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
         tokens: %{}
       }}
    else
      {:error, reason} -> {:stop, {:spawner_unavailable, reason}}
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
        send(server, {:channel, data})
        read_channel(channel, server)

      {:error, reason} ->
        send(server, {:channel_closed, reason})
    end
  end

  defp accept(listener, server) do
    case :gen_tcp.accept(listener) do
      {:ok, conn} ->
        handshake = spawn(fn -> receive(do: (:go -> handshake(conn, server))) end)

        case :gen_tcp.controlling_process(conn, handshake) do
          :ok -> send(handshake, :go)
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
  # process that asked for that spawn.
  defp handshake(conn, server) do
    with {:ok, <<@stream_attach, @token_hex_bytes::32>>} <-
           :gen_tcp.recv(conn, 5, @attach_timeout_ms),
         {:ok, token} <- :gen_tcp.recv(conn, @token_hex_bytes, @attach_timeout_ms),
         {:ok, owner, ref} <- GenServer.call(server, {:attach, token}),
         :ok <- :gen_tcp.controlling_process(conn, owner) do
      send(owner, {__MODULE__, ref, {:attached, conn}})
    else
      _ -> :gen_tcp.close(conn)
    end
  catch
    :exit, _ -> :gen_tcp.close(conn)
  end

  @impl GenServer
  def handle_call({:spawn, argv, env}, {owner, _tag}, state) do
    id = Integer.to_string(state.next_id + 1)
    token = 32 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

    message = %{
      v: @protocol_version,
      type: "spawn",
      id: id,
      pool: @pool,
      argv: argv,
      env: env,
      attach: %{path: state.attach_path, token: token}
    }

    with {:ok, line} <- Jason.encode(message),
         :ok <- send_line(state, line) do
      ref = make_ref()

      entry = %{
        owner: owner,
        monitor: Process.monitor(owner),
        id: id,
        token: token,
        spawn_id: nil,
        release_on_spawn: nil,
        released: false
      }

      {:reply, {:ok, ref},
       %{
         state
         | next_id: state.next_id + 1,
           requests: Map.put(state.requests, ref, entry),
           ids: Map.put(state.ids, id, ref),
           tokens: Map.put(state.tokens, token, ref)
       }}
    else
      {:error, %Jason.EncodeError{}} ->
        {:reply, {:error, {:spawn_failed, :unencodable_command}}, state}

      {:error, reason} ->
        {:stop, {:shutdown, {:channel_lost, reason}}, {:error, {:spawn_failed, :channel_lost}},
         state}
    end
  end

  def handle_call({:attach, token}, _from, state) do
    {ref, tokens} = Map.pop(state.tokens, token)
    state = %{state | tokens: tokens}

    case ref && state.requests[ref] do
      %{owner: owner} when is_pid(owner) -> {:reply, {:ok, owner, ref}, state}
      _ -> {:reply, :error, state}
    end
  end

  @impl GenServer
  def handle_cast({:release, ref, grace_ms}, state), do: {:noreply, release(state, ref, grace_ms)}

  # The caller's run is over. A spawn not yet reported retired is released
  # and forgotten once it is.
  def handle_cast({:done, ref}, state) do
    case state.requests[ref] do
      nil -> {:noreply, state}
      entry -> {:noreply, abandon(state, ref, entry)}
    end
  end

  @impl GenServer
  def handle_info({:channel, data}, state) do
    [rest | lines] = (state.buffer <> data) |> String.split("\n") |> Enum.reverse()

    if byte_size(rest) > @max_line_bytes do
      Logger.error(
        "[Locus.Spawner] FATAL: the spawner sent a line longer than #{@max_line_bytes} bytes"
      )

      {:stop, {:shutdown, :channel_fault}, state}
    else
      state = lines |> Enum.reverse() |> Enum.reduce(%{state | buffer: rest}, &on_line/2)
      {:noreply, state}
    end
  end

  def handle_info({:channel_closed, reason}, state) do
    Logger.error(
      "[Locus.Spawner] FATAL: the spawner channel closed (#{inspect(reason)}); builds stop"
    )

    for {ref, %{owner: owner}} <- state.requests,
        is_pid(owner),
        do: send(owner, {__MODULE__, ref, {:error, :channel_lost}})

    {:stop, {:shutdown, :channel_lost}, state}
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

  @impl GenServer
  def terminate(_reason, state) do
    :gen_tcp.close(state.listener)
    File.rm(state.attach_path)
    :ok
  end

  defp on_line("", state), do: state

  defp on_line(line, state) do
    case Jason.decode(line) do
      {:ok, %{"v" => @protocol_version} = message} -> on_message(message, state)
      _ -> state
    end
  end

  defp on_message(%{"type" => "spawned", "id" => id, "spawn_id" => spawn_id} = m, state) do
    with_request(state, state.ids[id], fn ref, entry ->
      notify(entry, ref, {:spawned, m["uid"], m["pid"]})
      state = %{state | spawns: Map.put(state.spawns, spawn_id, ref)}
      state = put_entry(state, ref, %{entry | spawn_id: spawn_id})

      case entry.release_on_spawn do
        nil -> state
        grace -> release(state, ref, grace)
      end
    end)
  end

  defp on_message(%{"type" => "error", "id" => id, "code" => code}, state) when is_binary(id) do
    with_request(state, state.ids[id], fn ref, entry ->
      notify(entry, ref, {:error, code})
      drop(state, ref)
    end)
  end

  # A release for a spawn cyfr-spawn no longer holds: its retirement is done.
  defp on_message(%{"type" => "error", "spawn_id" => spawn_id, "code" => "unknown_spawn"}, state),
    do: released(state, spawn_id)

  defp on_message(%{"type" => "exited", "spawn_id" => spawn_id} = m, state) do
    with_request(state, state.spawns[spawn_id], fn ref, entry ->
      notify(entry, ref, {:exited, m["code"], m["signal"]})
      state
    end)
  end

  defp on_message(%{"type" => "released", "spawn_id" => spawn_id}, state),
    do: released(state, spawn_id)

  defp on_message(_message, state), do: state

  # The entry stays until its caller is done, so a relay connection that
  # arrives after the report still reaches the caller.
  defp released(state, spawn_id) do
    with_request(state, state.spawns[spawn_id], fn ref, entry ->
      notify(entry, ref, :released)

      if entry.owner,
        do: %{
          put_entry(state, ref, %{entry | released: true})
          | spawns: Map.delete(state.spawns, spawn_id)
        },
        else: drop(state, ref)
    end)
  end

  defp abandon(state, ref, %{released: true}), do: drop(state, ref)

  defp abandon(state, ref, entry) do
    state
    |> put_entry(ref, %{entry | owner: nil})
    |> Map.update!(:tokens, &Map.delete(&1, entry.token))
    |> release(ref, 0)
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
    do: send(owner, {__MODULE__, ref, message})

  defp notify(_entry, _ref, _message), do: :ok

  defp drop(state, ref) do
    {entry, requests} = Map.pop(state.requests, ref)
    Process.demonitor(entry.monitor, [:flush])

    %{
      state
      | requests: requests,
        ids: Map.delete(state.ids, entry.id),
        spawns:
          if(entry.spawn_id, do: Map.delete(state.spawns, entry.spawn_id), else: state.spawns),
        tokens: Map.delete(state.tokens, entry.token)
    }
  end

  defp release(state, ref, grace_ms) do
    case state.requests[ref] do
      nil ->
        state

      %{spawn_id: nil} = entry ->
        put_entry(state, ref, %{
          entry
          | release_on_spawn: min(entry.release_on_spawn || grace_ms, grace_ms)
        })

      %{spawn_id: spawn_id} ->
        line =
          Jason.encode!(%{
            v: @protocol_version,
            type: "release",
            spawn_id: spawn_id,
            grace_ms: grace_ms
          })

        _ = send_line(state, line)
        state
    end
  end

  defp send_line(state, line),
    do: :socket.send(state.channel, [line, ?\n], @channel_send_timeout_ms)
end
