# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Keeper.Spawn do
  @moduledoc """
  The client of `cyfr-spawn` (`apps/spawn`), the keeper the image starts
  the service under, and the runners it starts in the keeper's `runner`
  uid pool.

  ## The channel

  `cyfr-spawn serve` starts the service with a socketpair on file
  descriptor 3 and `CYFR_SPAWN_CHANNEL` naming it. This process owns
  that channel, whose messages are JSON objects one per line (the
  protocol of `apps/spawn/internal/protocol`), and the attach socket in
  `:attach_dir` every runner's relay connects to.

  ## A runner

  A `spawn` request names the pool, the runner's argv and its explicit
  environment (only `OPUS_*` variables and the release's own: the keeper
  refuses `CYFR_` and `MCP_BRIDGE_` names, and sets `PATH`, `HOME`, `USER`,
  `LOGNAME` and `TMPDIR` itself), asks for a control channel
  (`"control": true`) and names the attach socket and a token. The keeper
  runs the command under a pooled uid with fd 3 as one end of an AF_UNIX
  socketpair, and its relay, running as the service's user, connects to
  the attach socket, presents the token and then carries the runner's
  streams as frames: a stream byte (0 stdin, 1 stdout, 2 stderr, 3 the
  token, 4 the control channel), a 4-byte big-endian length and at most
  64 KiB of payload; a zero-length frame ends its stream. Control bytes
  go both ways on stream 4: a `Cyfr.RunnerControl` line longer than a
  frame is split across frames and reassembled by its newline on the far
  side. A zero-length control frame from the relay means the runner
  closed its fd 3 or exited.

  `release` sends the runner's process group a term signal, the grace to
  report what it holds, then the kill, and retires the uid: every process
  of it killed and everything it left removed before another runner gets
  it. `exited` reports the leader's end and `released` the retirement.
  When the channel closes, `cyfr-spawn` has already retired every spawn
  and is exiting: every runner's owner hears `{:error, :channel_lost}`
  and this process stops, taking the pool and the service with it.

  ## The memory bound

  Every spawn this client asks for carries `memory_bytes`, the pool's
  `:runner_memory_bytes` (`Opus.Settings.runner_memory_bytes/1`), or the
  `:memory_bytes` it was started with; nothing asks for none. `cyfr-spawn`
  gives the runner a cgroup of its own at that bound: its VM, every
  guest's linear memory, the pages of its home and the kernel memory
  charged to it, together. A runner that cannot stay under it loses every
  process at once; the leader's `exited` then says `memory_exceeded`,
  read by `cyfr-spawn` from the group's own counters, and this client
  logs the runner's end at its bound before its owner hears the exit and
  the retirement that follow, as for any other runner's end: the pool
  taints it, the service reports it with the subtree it held, and its uid
  is retired and scrubbed before another runner gets it. Where
  `cyfr-spawn` cannot give a runner such a group it refuses the spawn as
  `memory_unavailable`, which the owner hears as
  `{:refused, :memory_unavailable}` (a spawn's refusal, as `refusal/1`
  reads it; any other code the keeper refuses one with is heard as it
  was sent), and this client logs what the deployment lacks:
  the container needs the `writable-cgroups=true` security option (Docker
  Engine 28 or later on a cgroup v2 host). No runner is started without
  its bound instead; the pool keeps none of the runners it was refused
  and backs off (`Opus.RunnerPool`).

  ## arca:bypass-ok=D — entire module

  The only paths are the attach directory and the attach socket inside
  it, the worker's own, which this process checks, creates and removes.
  """

  @behaviour Opus.Keeper

  use GenServer

  import Kernel, except: [send: 2]

  require Logger

  @channel_fd 3
  @protocol_version 1
  @pool "runner"
  @attach_socket "attach.sock"

  @stream_stdout 1
  @stream_stderr 2
  @stream_attach 3
  @stream_control 4
  @max_frame_bytes 65_536
  @token_hex_bytes 64
  @max_line_bytes 1_048_576

  # cyfr-spawn bounds a stage and a relay's dial at 10 s each.
  @start_timeout_ms 15_000
  @attach_timeout_ms 10_000
  @channel_send_timeout_ms 30_000
  @stats_timeout_ms 5_000

  @memory_unavailable "cyfr-spawn cannot bound a runner's memory in this container, so it " <>
                        "starts none: start the opus service with the security option " <>
                        "writable-cgroups=true (Docker Engine 28 or later on a cgroup v2 host)"

  @impl Opus.Keeper
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  @doc """
  Start the client. Options: `:channel`, a connected `:socket` to use in
  place of fd 3; `:attach_dir`, a directory only the service's user can
  enter; `:memory_bytes`, the bound every runner is spawned with in place
  of the pool's `:runner_memory_bytes`, in the same range and never none;
  `:name` (default `#{inspect(__MODULE__)}`).
  """
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "The uid pool a runner is spawned in."
  @spec pool() :: String.t()
  def pool, do: @pool

  @impl Opus.Keeper
  def available(env, opts) do
    cond do
      Keyword.has_key?(opts, :channel) ->
        :ok

      Opus.Settings.channel_inherited?(env) ->
        :ok

      true ->
        {:error, "no keeper channel was inherited (#{Opus.Settings.channel_env()} is not set)"}
    end
  end

  @impl Opus.Keeper
  def spawn(%{runner: runner, argv: argv, env: env} = spec) do
    case GenServer.call(server(spec), {:spawn, runner, argv, env, self()}, @start_timeout_ms) do
      {:ok, ref} -> {:ok, %{ref: ref, server: server(spec)}, []}
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, reason -> {:error, {:keeper_unavailable, reason}}
  end

  @impl Opus.Keeper
  def handle_message(%{ref: ref} = channel, {__MODULE__, ref, event}),
    do: {:events, [event], channel}

  def handle_message(_channel, _message), do: :unknown

  @impl Opus.Keeper
  def send(%{ref: ref, server: server}, data) do
    GenServer.call(server, {:send, ref, IO.iodata_to_binary(data)}, @channel_send_timeout_ms)
  catch
    :exit, reason -> {:error, {:keeper_unavailable, reason}}
  end

  @impl Opus.Keeper
  def release(%{ref: ref, server: server}, grace_ms) when is_integer(grace_ms) and grace_ms >= 0,
    do: GenServer.cast(server, {:release, ref, grace_ms})

  @impl Opus.Keeper
  def memory_bytes(opts) when is_list(opts) do
    case bound(opts) do
      {:ok, bytes} -> bytes
      {:error, _malformed} -> nil
    end
  end

  # The keeper's refusals of a spawn: its code, and what an operator makes
  # of it. `memory_unavailable` names what the deployment lacks.
  @impl Opus.Keeper
  def refusal(:memory_unavailable),
    do: %{reason: "memory_unavailable", message: @memory_unavailable}

  def refusal(code) when is_binary(code) do
    reason = if Regex.match?(~r/\A[a-z][a-z0-9_]{0,63}\z/, code), do: code, else: "refused"
    %{reason: reason, message: "cyfr-spawn refused to start a runner (#{reason})"}
  end

  def refusal(_reason),
    do: %{reason: "refused", message: "cyfr-spawn refused to start a runner"}

  @impl Opus.Keeper
  def stats, do: stats(__MODULE__)

  @doc "`stats/0` through the client `server`."
  @spec stats(GenServer.server()) ::
          {:ok,
           %{size: non_neg_integer(), free: non_neg_integer(), quarantined: non_neg_integer()}}
          | :unknown
  def stats(server) do
    GenServer.call(server, :stats, @stats_timeout_ms)
  catch
    :exit, _reason -> :unknown
  end

  # A spec may name the client to use (`:server`), as a test does; the
  # pool's runners use the registered one.
  defp server(spec), do: Map.get(spec, :server, __MODULE__)

  # ---------------------------------------------------------------------------
  # The client
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    with {:ok, memory_bytes} <- bound(opts),
         {:ok, channel} <- open_channel(opts),
         {:ok, listener, path} <- listen(Keyword.fetch!(opts, :attach_dir)) do
      server = self()

      {:ok,
       %{
         channel: channel,
         listener: listener,
         attach_path: path,
         memory_bytes: memory_bytes,
         bound_refused: false,
         reader: spawn_link(fn -> read_channel(channel, server) end),
         acceptor: spawn_link(fn -> accept(listener, server) end),
         buffer: "",
         next_id: 0,
         requests: %{},
         ids: %{},
         spawns: %{},
         tokens: %{},
         conns: %{},
         stats: %{}
       }}
    else
      {:error, reason} -> {:stop, {:keeper_unavailable, reason}}
    end
  end

  # The bound every spawn carries: the one the client was started with, or
  # the pool's setting; a malformed one stops the client, and the pool and
  # service with it, rather than start a runner without it.
  defp bound(opts) do
    env =
      case Keyword.fetch(opts, :memory_bytes) do
        {:ok, bytes} -> [runner_memory_bytes: bytes]
        :error -> Application.get_all_env(:opus)
      end

    Opus.Settings.runner_memory_bytes(env)
  end

  defp open_channel(opts) do
    case Keyword.fetch(opts, :channel) do
      {:ok, channel} -> {:ok, channel}
      :error -> :socket.open(@channel_fd)
    end
  end

  defp listen(dir) do
    path = Path.join(dir, @attach_socket)

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

  # A relay's first frame is its spawn's token; the connection then
  # belongs to this client, which reads its frames for the spawn's owner.
  defp handshake(conn, server) do
    with {:ok, <<@stream_attach, @token_hex_bytes::32>>} <-
           :gen_tcp.recv(conn, 5, @attach_timeout_ms),
         {:ok, token} <- :gen_tcp.recv(conn, @token_hex_bytes, @attach_timeout_ms),
         :ok <- :gen_tcp.controlling_process(conn, server),
         :ok <- GenServer.call(server, {:attach, token, conn}) do
      :ok
    else
      _ -> :gen_tcp.close(conn)
    end
  catch
    :exit, _ -> :gen_tcp.close(conn)
  end

  @impl GenServer
  def handle_call({:spawn, runner, argv, env, owner}, _from, state) do
    id = Integer.to_string(state.next_id + 1)
    token = 32 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

    message = %{
      v: @protocol_version,
      type: "spawn",
      id: id,
      pool: @pool,
      argv: argv,
      env: env,
      memory_bytes: state.memory_bytes,
      control: true,
      attach: %{path: state.attach_path, token: token}
    }

    with {:ok, line} <- Jason.encode(message),
         :ok <- send_line(state, line) do
      ref = make_ref()

      entry = %{
        owner: owner,
        monitor: Process.monitor(owner),
        runner: runner,
        id: id,
        token: token,
        spawn_id: nil,
        conn: nil,
        frames: "",
        pending: [],
        control_open: true,
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

  def handle_call({:send, ref, data}, _from, state) do
    case state.requests[ref] do
      nil ->
        {:reply, {:error, :unknown_runner}, state}

      %{conn: nil} = entry ->
        {:reply, :ok, put_entry(state, ref, %{entry | pending: [entry.pending, data]})}

      %{conn: conn} ->
        {:reply, :gen_tcp.send(conn, control_frames(data)), state}
    end
  end

  def handle_call({:attach, token, conn}, _from, state) do
    {ref, tokens} = Map.pop(state.tokens, token)
    state = %{state | tokens: tokens}

    case ref && state.requests[ref] do
      %{conn: nil} = entry ->
        _ = :gen_tcp.send(conn, control_frames(IO.iodata_to_binary(entry.pending)))
        :ok = :inet.setopts(conn, active: true)
        notify(entry, ref, :attached)

        {:reply, :ok,
         %{
           put_entry(state, ref, %{entry | conn: conn, pending: []})
           | conns: Map.put(state.conns, conn, ref)
         }}

      _ ->
        {:reply, :error, state}
    end
  end

  def handle_call(:stats, from, state) do
    id = "pool-" <> Integer.to_string(state.next_id + 1)
    line = Jason.encode!(%{v: @protocol_version, type: "pool", id: id, pool: @pool})

    case send_line(state, line) do
      :ok ->
        {:noreply, %{state | next_id: state.next_id + 1, stats: Map.put(state.stats, id, from)}}

      {:error, reason} ->
        {:stop, {:shutdown, {:channel_lost, reason}}, :unknown, state}
    end
  end

  @impl GenServer
  def handle_cast({:release, ref, grace_ms}, state), do: {:noreply, release(state, ref, grace_ms)}

  @impl GenServer
  def handle_info({:channel, data}, state) do
    [rest | lines] = (state.buffer <> data) |> String.split("\n") |> Enum.reverse()

    if byte_size(rest) > @max_line_bytes do
      Logger.error(
        "[Opus.Keeper.Spawn] FATAL: the keeper sent a line longer than #{@max_line_bytes} bytes"
      )

      {:stop, {:shutdown, :channel_fault}, state}
    else
      state = lines |> Enum.reverse() |> Enum.reduce(%{state | buffer: rest}, &on_line/2)
      {:noreply, state}
    end
  end

  def handle_info({:channel_closed, reason}, state) do
    Logger.error(
      "[Opus.Keeper.Spawn] FATAL: the keeper channel closed (#{inspect(reason)}); runners stop"
    )

    for {ref, entry} <- state.requests, do: notify(entry, ref, {:error, :channel_lost})
    for {_id, from} <- state.stats, do: GenServer.reply(from, :unknown)

    {:stop, {:shutdown, :channel_lost}, state}
  end

  def handle_info({:tcp, conn, data}, state) do
    case state.conns[conn] do
      nil ->
        :gen_tcp.close(conn)
        {:noreply, state}

      ref ->
        {:noreply, on_frames(state, ref, conn, data)}
    end
  end

  def handle_info({:tcp_closed, conn}, state), do: {:noreply, conn_gone(state, conn)}

  def handle_info({:tcp_error, conn, _reason}, state) do
    :gen_tcp.close(conn)
    {:noreply, conn_gone(state, conn)}
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

  def handle_info(msg, state) do
    Cyfr.LoggerContext.unexpected(__MODULE__, msg)
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    :gen_tcp.close(state.listener)
    File.rm(state.attach_path)
    :ok
  end

  # Control bytes held for a relay that has not attached are an `assign`,
  # which carries an attempt's opened keys, and so is the call that sent
  # them; an attach token admits a relay as its runner. No status or crash
  # report shows more of them than their size, and the debug log, which
  # holds them, is left out.
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

      {:message, {:send, ref, data}} ->
        {:message, {:send, ref, {:redacted, byte_size(data)}}}

      {:message, {:attach, _token, conn}} ->
        {:message, {:attach, :redacted, conn}}

      {:log, _log} ->
        {:log, []}

      other ->
        other
    end)
  end

  defp redact(entry),
    do: %{entry | token: :redacted, pending: {:redacted, IO.iodata_length(entry.pending)}}

  # ————— the keeper's lines —————

  defp on_line("", state), do: state

  defp on_line(line, state) do
    case Jason.decode(line) do
      {:ok, %{"v" => @protocol_version} = message} -> on_message(message, state)
      _ -> state
    end
  end

  defp on_message(%{"type" => "spawned", "id" => id, "spawn_id" => spawn_id} = m, state) do
    with_request(state, state.ids[id], fn ref, entry ->
      notify(entry, ref, {:spawned, m["pid"]})
      state = %{state | spawns: Map.put(state.spawns, spawn_id, ref), bound_refused: false}
      state = put_entry(state, ref, %{entry | spawn_id: spawn_id})

      case entry.release_on_spawn do
        nil -> state
        grace -> release(state, ref, grace)
      end
    end)
  end

  defp on_message(%{"type" => "error", "id" => id, "code" => code}, state) when is_binary(id) do
    case Map.pop(state.stats, id) do
      {nil, _stats} ->
        with_request(state, state.ids[id], fn ref, entry ->
          state = refused(state, entry, code)
          notify(entry, ref, {:refused, typed(code)})
          drop(state, ref)
        end)

      {from, stats} ->
        GenServer.reply(from, :unknown)
        %{state | stats: stats}
    end
  end

  # A release for a spawn the keeper no longer holds: its retirement is done.
  defp on_message(%{"type" => "error", "spawn_id" => spawn_id, "code" => "unknown_spawn"}, state),
    do: released(state, spawn_id)

  defp on_message(%{"type" => "exited", "spawn_id" => spawn_id} = m, state) do
    with_request(state, state.spawns[spawn_id], fn ref, entry ->
      exit = if m["signal"], do: {:signal, m["signal"]}, else: {:status, m["code"]}

      # cyfr-spawn read it from the group's own counters: the kernel killed
      # the runner at its bound, not for the container's limit.
      if m["memory_exceeded"] == true do
        Logger.warning(
          "[Opus.Keeper.Spawn] runner #{entry.runner} was ended at its memory bound of " <>
            "#{state.memory_bytes} bytes (spawn #{spawn_id}, #{format_exit(exit)})"
        )
      end

      notify(entry, ref, {:exited, exit})
      state
    end)
  end

  defp on_message(%{"type" => "released", "spawn_id" => spawn_id}, state),
    do: released(state, spawn_id)

  defp on_message(%{"type" => "pool", "id" => id} = m, state) do
    case Map.pop(state.stats, id) do
      {nil, _stats} ->
        state

      {from, stats} ->
        GenServer.reply(
          from,
          {:ok, %{size: m["size"], free: m["free"], quarantined: m["quarantined"]}}
        )

        %{state | stats: stats}
    end
  end

  defp on_message(_message, state), do: state

  defp released(state, spawn_id) do
    with_request(state, state.spawns[spawn_id], fn ref, entry ->
      notify(entry, ref, :released)
      drop(state, ref)
    end)
  end

  # A spawn refused because its bound cannot be enforced here is typed;
  # every other refusal is the keeper's code as it sent it.
  defp typed("memory_unavailable"), do: :memory_unavailable
  defp typed(code), do: code

  # What the deployment lacks is logged once for each run of refusals; a
  # runner spawned again under its bound ends the run.
  defp refused(%{bound_refused: false} = state, entry, "memory_unavailable") do
    Logger.error(
      "[Opus.Keeper.Spawn] runner #{entry.runner} was not started: #{@memory_unavailable}"
    )

    %{state | bound_refused: true}
  end

  defp refused(state, _entry, _code), do: state

  defp format_exit({:signal, signal}), do: "signal #{signal}"
  defp format_exit({:status, code}), do: "status #{code}"

  # ————— a relay's frames —————

  defp on_frames(state, ref, conn, data) do
    case state.requests[ref] do
      nil -> state
      entry -> parse_frames(state, ref, conn, %{entry | frames: entry.frames <> data})
    end
  end

  defp parse_frames(state, ref, conn, %{frames: <<stream, length::32, rest::binary>>} = entry)
       when byte_size(rest) >= length and length <= @max_frame_bytes do
    <<payload::binary-size(^length), rest::binary>> = rest
    entry = %{entry | frames: rest}

    case on_frame(entry, ref, stream, payload) do
      {:ok, entry} -> parse_frames(state, ref, conn, entry)
      :fault -> relay_fault(put_entry(state, ref, entry), ref, conn)
    end
  end

  defp parse_frames(state, ref, conn, %{frames: <<_stream, length::32, _::binary>>})
       when length > @max_frame_bytes,
       do: relay_fault(state, ref, conn)

  defp parse_frames(state, ref, _conn, entry), do: put_entry(state, ref, entry)

  defp on_frame(%{control_open: true} = entry, ref, @stream_control, ""),
    do: {:ok, notify_entry(%{entry | control_open: false}, ref, :control_closed)}

  defp on_frame(entry, _ref, @stream_control, ""), do: {:ok, entry}

  defp on_frame(entry, ref, @stream_control, payload),
    do: {:ok, notify_entry(entry, ref, {:control, payload})}

  defp on_frame(entry, _ref, stream, "") when stream in [@stream_stdout, @stream_stderr],
    do: {:ok, entry}

  defp on_frame(entry, ref, stream, payload) when stream in [@stream_stdout, @stream_stderr],
    do: {:ok, notify_entry(entry, ref, {:log, payload})}

  defp on_frame(_entry, _ref, _stream, _payload), do: :fault

  defp notify_entry(entry, ref, event) do
    notify(entry, ref, event)
    entry
  end

  defp relay_fault(state, ref, conn) do
    :gen_tcp.close(conn)

    with_request(conn_gone(state, conn), ref, fn ref, entry ->
      notify(entry, ref, {:error, :relay_protocol})
      state
    end)
  end

  # The relay's connection is gone: the runner's end of the channel is
  # closed with it, if it was not reported so already.
  defp conn_gone(state, conn) do
    {ref, conns} = Map.pop(state.conns, conn)
    state = %{state | conns: conns}

    with_request(state, ref, fn ref, entry ->
      entry =
        if entry.control_open,
          do: notify_entry(%{entry | control_open: false}, ref, :control_closed),
          else: entry

      put_entry(state, ref, %{entry | conn: nil})
    end)
  end

  @doc false
  # Control bytes split into frames of at most the relay's payload bound.
  def control_frames(<<chunk::binary-size(@max_frame_bytes), rest::binary>>),
    do: [frame(@stream_control, chunk) | control_frames(rest)]

  def control_frames(<<>>), do: []
  def control_frames(chunk) when is_binary(chunk), do: [frame(@stream_control, chunk)]

  @doc false
  # The zero-length control frame: the sender's end of the channel is closed.
  def end_frame, do: frame(@stream_control, "")

  defp frame(stream, payload), do: [<<stream, byte_size(payload)::32>>, payload]

  # ————— the requests —————

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

  defp release(state, ref, grace_ms) do
    case state.requests[ref] do
      nil ->
        state

      %{spawn_id: nil} = entry ->
        put_entry(state, ref, %{
          entry
          | release_on_spawn: min(entry.release_on_spawn || grace_ms, grace_ms)
        })

      %{spawn_id: spawn_id} = entry ->
        line =
          Jason.encode!(%{
            v: @protocol_version,
            type: "release",
            spawn_id: spawn_id,
            grace_ms: grace_ms
          })

        _ = send_line(state, line)
        put_entry(state, ref, %{entry | released: true})
    end
  end

  defp send_line(state, line),
    do: :socket.send(state.channel, [line, ?\n], @channel_send_timeout_ms)
end
