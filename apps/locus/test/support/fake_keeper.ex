# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Test.FakeKeeper do
  @moduledoc """
  The far end of a `Locus.Keeper` channel, standing in for cyfr-locus: it
  answers a spawn by running the command on this machine as the test's own
  user and acting as its relay — it dials the request's attach socket,
  presents the token, reads stdin frames, and sends the command's stderr as
  it arrives and its stdout at exit — then reports `exited` and `released`.
  A `release` kills the command. It isolates nothing; it exercises the
  client's side of the protocol.

  Modes, set with `mode/2`:
  - `:normal`
  - `:capacity` — every spawn is refused with `capacity`
  - `:memory_unavailable` — every spawn is refused with `memory_unavailable`,
    as a keeper whose cgroup is not writable refuses a bounded spawn
  - `{:exit, exited}` — the command is never run: the relay writes one log
    line and the leader is reported ended as `exited` says (`:code`,
    `:signal`, `:memory_exceeded`), killed at its memory bound among them
  - `{:report_first, reported?}` — a build's command runs before its relay
    dials, so on no input, and its `exited` and `released` are written to
    the channel; the relay waits until `reported?` (a function of no
    arguments) holds, the client having read them, then dials, presents
    the token, reads the stdin the client sends and drops it, and sends
    the command's output. In every other mode a build's relay dials first
    and the command reads the stdin the client sends.
  - `:pool_refused` — every `pool` request is refused with `unknown_pool`

  A spawn in any pool but `build` is long-lived: its relay carries stdin
  frames to the command as they arrive and its stdout and stderr, apart,
  as the command writes them, until the command exits. A `signal` request
  signals its process group; a `release` with a grace sends it a term
  signal and the kill once the grace passes. A `pool` request is answered
  with a pool of four uids, three free and none quarantined.
  """

  use GenServer

  @stream_stdin 0
  @stream_stdout 1
  @stream_stderr 2
  @stream_attach 3

  # Named by absolute path, as the direct launcher names its tools: a test
  # that moves this node's PATH must not lose a fifo. Signals go through
  # the direct launcher's group signal (`Locus.DirectLauncher.signal_group/2`).
  @mkfifo "/usr/bin/mkfifo"

  @doc "Starts a fake and answers `{fake, client_channel}`, the `:socket` to hand `Locus.Keeper`."
  def start do
    dir = short_tmp_dir()
    path = Path.join(dir, "channel.sock")
    {:ok, listener} = :socket.open(:local, :stream)
    :ok = :socket.bind(listener, %{family: :local, path: path})
    :ok = :socket.listen(listener)
    {:ok, client} = :socket.open(:local, :stream)
    :ok = :socket.connect(client, %{family: :local, path: path})
    {:ok, ours} = :socket.accept(listener)
    :socket.close(listener)
    File.rm_rf!(dir)
    {:ok, fake} = GenServer.start(__MODULE__, ours)
    :ok = :socket.setopt(ours, {:otp, :controlling_process}, fake)
    {fake, client}
  end

  @doc """
  A fake and a `Locus.Keeper` client on its channel, both stopped and the
  client's attach directory removed when the calling test ends: answers
  `%{fake: fake, name: client, client: client}`, the client addressed
  by its pid.
  """
  def start_client! do
    {fake, channel} = start()
    attach_dir = short_tmp_dir()

    ExUnit.Callbacks.on_exit(fn ->
      Process.exit(fake, :kill)
      File.rm_rf!(attach_dir)
    end)

    {:ok, client} = Locus.Keeper.start_link(channel: channel, attach_dir: attach_dir, name: nil)
    Process.unlink(client)
    ExUnit.Callbacks.on_exit(fn -> Process.exit(client, :kill) end)
    :ok = :socket.setopt(channel, {:otp, :controlling_process}, client)
    %{fake: fake, name: client, client: client}
  end

  @doc """
  A private directory short enough for a unix socket path, new to this
  call: its name carries this VM's OS pid, so another partition's is
  never the same one, and a directory an earlier run left behind under a
  reused pid is passed over.
  """
  def short_tmp_dir do
    dir = Path.join("/tmp", "lsp-#{System.pid()}-#{System.unique_integer([:positive])}")

    case File.mkdir(dir) do
      :ok ->
        File.chmod!(dir, 0o700)
        dir

      {:error, :eexist} ->
        short_tmp_dir()
    end
  end

  def mode(fake, mode), do: GenServer.call(fake, {:mode, mode})

  @doc "Every request received so far, decoded, oldest first."
  def requests(fake), do: GenServer.call(fake, :requests)

  @doc "The spawn ids whose exit the fake has reported, in order."
  def exits(fake), do: GenServer.call(fake, :exits)

  @doc """
  What the fake has done of every spawn's end, in the order it did it:
  `:exited` and `:released` once the report is written to the channel,
  `:dial` once the relay has connected and written its token.
  """
  def sent(fake), do: GenServer.call(fake, :sent)

  @doc "Every command directory the fake's relays made, oldest first; each is removed when its relay ends."
  def command_dirs(fake), do: GenServer.call(fake, :command_dirs)

  @doc "The spawn ids whose command the fake runs or has run, as an OS process it can signal."
  def running(fake), do: GenServer.call(fake, :running)

  @doc "Closes the channel, as cyfr-locus exiting would."
  def close(fake), do: GenServer.call(fake, :close)

  @impl true
  def init(channel) do
    fake = self()
    spawn_link(fn -> read(channel, fake) end)

    {:ok,
     %{
       channel: channel,
       buffer: "",
       mode: :normal,
       requests: [],
       exits: [],
       sent: [],
       command_dirs: [],
       spawns: %{},
       next: 0
     }}
  end

  defp read(channel, fake) do
    case :socket.recv(channel, 0, :infinity) do
      {:ok, data} ->
        send(fake, {:data, data})
        read(channel, fake)

      {:error, _} ->
        :ok
    end
  end

  @impl true
  def handle_call({:mode, mode}, _from, state), do: {:reply, :ok, %{state | mode: mode}}
  def handle_call(:requests, _from, state), do: {:reply, Enum.reverse(state.requests), state}
  def handle_call(:exits, _from, state), do: {:reply, Enum.reverse(state.exits), state}
  def handle_call(:sent, _from, state), do: {:reply, Enum.reverse(state.sent), state}

  def handle_call(:command_dirs, _from, state),
    do: {:reply, Enum.reverse(state.command_dirs), state}

  def handle_call(:running, _from, state),
    do: {:reply, for({spawn_id, os_pid} <- state.spawns, is_integer(os_pid), do: spawn_id), state}

  # A relay's report written before it answers, so what the relay does
  # next follows it on the channel.
  def handle_call({:send, message}, _from, state), do: {:reply, :ok, write(state, message)}
  def handle_call(:dialed, _from, state), do: {:reply, :ok, %{state | sent: [:dial | state.sent]}}

  def handle_call(:close, _from, state) do
    :socket.close(state.channel)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:data, data}, state) do
    [rest | lines] = (state.buffer <> data) |> String.split("\n") |> Enum.reverse()

    state =
      lines
      |> Enum.reverse()
      |> Enum.reduce(%{state | buffer: rest}, fn line, acc ->
        request = Jason.decode!(line)
        handle_request(request, %{acc | requests: [request | acc.requests]})
      end)

    {:noreply, state}
  end

  def handle_info({:send, message}, state), do: {:noreply, write(state, message)}

  def handle_info({:command_dir, dir}, state),
    do: {:noreply, %{state | command_dirs: [dir | state.command_dirs]}}

  # A signal asked for before the command's pid was known is sent now.
  def handle_info({:running, spawn_id, os_pid}, state) do
    with {:held, sigs} <- state.spawns[spawn_id],
         do: for(sig <- Enum.reverse(sigs), do: Locus.DirectLauncher.signal_group(os_pid, sig))

    {:noreply, put_in(state.spawns[spawn_id], os_pid)}
  end

  def handle_info({:kill_after, spawn_id}, state), do: {:noreply, signal(state, spawn_id, "KILL")}

  def handle_info(_message, state), do: {:noreply, state}

  # An exit the fake reports is recorded, so a test can tell a spawn the
  # keeper saw end from one it had to release; an exit and a release are
  # recorded only once the channel took them.
  defp write(state, message) do
    sent = :socket.send(state.channel, [Jason.encode!(Map.put(message, :v, 1)), ?\n])

    case message do
      _message when sent != :ok ->
        state

      %{type: "exited", spawn_id: spawn_id} ->
        %{state | exits: [spawn_id | state.exits], sent: [:exited | state.sent]}

      %{type: "released"} ->
        %{state | sent: [:released | state.sent]}

      _other ->
        state
    end
  end

  defp handle_request(%{"type" => "spawn", "id" => id}, %{mode: mode} = state)
       when mode in [:capacity, :memory_unavailable] do
    send(self(), {:send, %{type: "error", id: id, code: Atom.to_string(mode)}})
    state
  end

  defp handle_request(%{"type" => "pool", "id" => id}, %{mode: :pool_refused} = state) do
    send(self(), {:send, %{type: "error", id: id, code: "unknown_pool"}})
    state
  end

  defp handle_request(%{"type" => "pool", "id" => id, "pool" => pool}, state) do
    send(
      self(),
      {:send, %{type: "pool", id: id, pool: pool, size: 4, free: 3, quarantined: 0}}
    )

    state
  end

  defp handle_request(
         %{"type" => "signal", "spawn_id" => spawn_id, "sig" => "SIG" <> sig},
         state
       ),
       do: signal(state, spawn_id, sig)

  defp handle_request(
         %{"type" => "release", "spawn_id" => spawn_id, "grace_ms" => grace_ms},
         state
       )
       when grace_ms > 0 do
    Process.send_after(self(), {:kill_after, spawn_id}, grace_ms)
    signal(state, spawn_id, "TERM")
  end

  defp handle_request(%{"type" => "spawn"} = request, state) do
    spawn_id = 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

    send(
      self(),
      {:send, %{type: "spawned", id: request["id"], spawn_id: spawn_id, uid: 30_001, pid: 1}}
    )

    fake = self()
    mode = state.mode
    spawn(fn -> relay(fake, spawn_id, request, mode) end)
    %{state | spawns: Map.put(state.spawns, spawn_id, nil)}
  end

  defp handle_request(%{"type" => "release", "spawn_id" => spawn_id}, state),
    do: signal(state, spawn_id, "KILL")

  defp handle_request(_request, state), do: state

  # A spawn whose command has not yet started holds the signal until it
  # does, as cyfr-locus signals a spawn it has answered whether or not its
  # command runs yet; an unknown spawn takes none.
  defp signal(state, spawn_id, sig) do
    case Map.fetch(state.spawns, spawn_id) do
      {:ok, os_pid} when is_integer(os_pid) ->
        Locus.DirectLauncher.signal_group(os_pid, sig)
        state

      {:ok, nil} ->
        put_in(state.spawns[spawn_id], {:held, [sig]})

      {:ok, {:held, sigs}} ->
        put_in(state.spawns[spawn_id], {:held, [sig | sigs]})

      :error ->
        state
    end
  end

  # A relay's command directory is recorded, and removed however the relay
  # ends: a client or channel gone mid-run ends it before its last frames.
  defp relay(fake, spawn_id, request, mode) do
    dir = short_tmp_dir()
    send(fake, {:command_dir, dir})

    try do
      relay(fake, spawn_id, request, mode, dir)
    after
      File.rm_rf!(dir)
    end
  end

  defp relay(fake, spawn_id, %{"pool" => "build"} = request, {:report_first, reported?}, dir) do
    input = Path.join(dir, "stdin")
    output = Path.join(dir, "stdout")
    File.write!(input, "")

    {exited, stdout, stderr} = run(fake, spawn_id, request, nil, {dir, input, output})
    :ok = GenServer.call(fake, {:send, exited})
    :ok = GenServer.call(fake, {:send, %{type: "released", spawn_id: spawn_id}})
    Prima.Test.Wait.wait_until(reported?, 5_000, "the client to read the release report")

    conn = dial(fake, request)
    _stdin = read_stdin(conn, [])
    finish(conn, [frames(@stream_stderr, stderr), frames(@stream_stdout, stdout)])
  end

  defp relay(fake, spawn_id, request, mode, dir) do
    input = Path.join(dir, "stdin")
    output = Path.join(dir, "stdout")
    conn = dial(fake, request)

    if request["pool"] == "build",
      do: run_build(fake, spawn_id, request, mode, conn, {dir, input, output}),
      else: live(fake, spawn_id, request, conn, dir)
  end

  defp dial(fake, request) do
    {:ok, conn} =
      :gen_tcp.connect({:local, request["attach"]["path"]}, 0, [
        :binary,
        active: false,
        packet: :raw
      ])

    :ok = :gen_tcp.send(conn, frame(@stream_attach, request["attach"]["token"]))
    :ok = GenServer.call(fake, :dialed)
    conn
  end

  defp run_build(fake, spawn_id, request, mode, conn, {dir, input, output}) do
    File.write!(input, read_stdin(conn, []))

    case mode do
      {:exit, exited} ->
        finish(conn, [frames(@stream_stderr, "the command's last words\n")])
        send(fake, {:send, Map.merge(%{type: "exited", spawn_id: spawn_id}, exited)})
        send(fake, {:send, %{type: "released", spawn_id: spawn_id}})

      _mode ->
        {exited, stdout, ""} = run(fake, spawn_id, request, conn, {dir, input, output})
        finish(conn, [frames(@stream_stdout, stdout)])
        send(fake, {:send, exited})
        send(fake, {:send, %{type: "released", spawn_id: spawn_id}})
    end
  end

  # The relay's last frames, then the end of both streams.
  defp finish(conn, frames) do
    :gen_tcp.send(conn, [frames, frame(@stream_stdout, ""), frame(@stream_stderr, "")])
    :gen_tcp.close(conn)
  end

  # The command's stderr goes to `conn` as it arrives, or is held for a
  # relay that has not dialled; its stdout is read at its exit.
  defp run(fake, spawn_id, request, conn, {dir, input, output}) do
    env = Enum.map(request["env"], fn {k, v} -> "#{k}=#{v}" end)

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        cd: dir,
        args:
          ["-c", ~s(exec 2>&1 >"$1" <"$2" && shift 2 && exec "$@"), "fake", output, input] ++
            ["/usr/bin/env", "-i", "HOME=#{dir}", "PATH=#{System.get_env("PATH")}" | env] ++
            request["argv"]
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    send(fake, {:running, spawn_id, os_pid})
    {status, stderr} = pump(port, conn, [])

    exited = %{
      type: "exited",
      spawn_id: spawn_id,
      code: status,
      signal: nil,
      memory_exceeded: false
    }

    exited =
      if status == 137, do: %{exited | code: nil, signal: "SIGKILL"}, else: exited

    {exited, File.read!(output), stderr}
  end

  # A long-lived spawn: stdin frames reach the command as they arrive, its
  # stdout and its stderr (through a fifo `cat` relays) go back apart as
  # it writes them, and its exit ends the relay.
  defp live(fake, spawn_id, request, conn, dir) do
    log = Path.join(dir, "stderr")
    {_, 0} = System.cmd(@mkfifo, ["-m", "600", log], env: Locus.Test.ProcessFamily.no_env())
    env = Enum.map(request["env"], fn {k, v} -> "#{k}=#{v}" end)

    port =
      Port.open({:spawn_executable, "/usr/bin/env"}, [
        :binary,
        :stream,
        :exit_status,
        :use_stdio,
        cd: dir,
        args:
          ["-i", "HOME=#{dir}", "PATH=#{System.get_env("PATH")}" | env] ++
            ["/bin/sh", "-c", ~s(exec "$@" 2>"$0"), log] ++ request["argv"]
      ])

    relay = Port.open({:spawn_executable, "/bin/cat"}, [:binary, :stream, :eof, args: [log]])

    # A command that has already exited has closed its port, which then
    # names no pid.
    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, os_pid} -> os_pid
        nil -> nil
      end

    send(fake, {:running, spawn_id, os_pid})

    pump = self()
    reader = spawn_link(fn -> read_frames(conn, pump) end)
    status = pump_live(port, relay, conn)
    Process.unlink(reader)
    Process.exit(reader, :kill)

    # What is left of the group goes, and the stderr relay drains.
    Locus.DirectLauncher.signal_group(os_pid, "KILL")
    System.cmd("/bin/sh", ["-c", ~s(exec 3<>"$0"), log], env: Locus.Test.ProcessFamily.no_env())
    drain_relay(relay, conn)

    :gen_tcp.send(conn, [frame(@stream_stdout, ""), frame(@stream_stderr, "")])
    :gen_tcp.close(conn)

    exited =
      if status > 128,
        do: %{code: nil, signal: signal_name(status - 128)},
        else: %{code: status, signal: nil}

    send(
      fake,
      {:send, Map.merge(%{type: "exited", spawn_id: spawn_id, memory_exceeded: false}, exited)}
    )

    send(fake, {:send, %{type: "released", spawn_id: spawn_id}})
  end

  defp signal_name(9), do: "SIGKILL"
  defp signal_name(15), do: "SIGTERM"
  defp signal_name(2), do: "SIGINT"
  defp signal_name(n), do: "SIG#{n}"

  defp read_frames(conn, pump) do
    with {:ok, <<stream, length::32>>} <- :gen_tcp.recv(conn, 5),
         {:ok, payload} <- if(length == 0, do: {:ok, ""}, else: :gen_tcp.recv(conn, length)) do
      send(pump, {:frame, stream, payload})
      read_frames(conn, pump)
    end
  end

  defp pump_live(port, relay, conn) do
    receive do
      {:frame, @stream_stdin, ""} ->
        pump_live(port, relay, conn)

      {:frame, @stream_stdin, payload} ->
        Port.command(port, payload)
        pump_live(port, relay, conn)

      {^port, {:data, data}} ->
        :gen_tcp.send(conn, frames(@stream_stdout, data))
        pump_live(port, relay, conn)

      {^relay, {:data, data}} ->
        :gen_tcp.send(conn, frames(@stream_stderr, data))
        pump_live(port, relay, conn)

      {^port, {:exit_status, status}} ->
        status
    end
  end

  defp drain_relay(relay, conn) do
    receive do
      {^relay, {:data, data}} ->
        :gen_tcp.send(conn, frames(@stream_stderr, data))
        drain_relay(relay, conn)

      {^relay, :eof} ->
        :ok
    after
      1_000 -> :ok
    end
  end

  defp read_stdin(conn, acc) do
    {:ok, <<@stream_stdin, length::32>>} = :gen_tcp.recv(conn, 5, 5_000)

    case length do
      0 ->
        Enum.reverse(acc)

      n ->
        {:ok, payload} = :gen_tcp.recv(conn, n, 5_000)
        read_stdin(conn, [payload | acc])
    end
  end

  defp pump(port, conn, held) do
    receive do
      {^port, {:data, data}} when conn == nil ->
        pump(port, conn, [held | data])

      {^port, {:data, data}} ->
        :gen_tcp.send(conn, frames(@stream_stderr, data))
        pump(port, conn, held)

      {^port, {:exit_status, status}} ->
        {status, IO.iodata_to_binary(held)}
    end
  end

  defp frames(stream, <<chunk::binary-size(65_536), rest::binary>>),
    do: [frame(stream, chunk) | frames(stream, rest)]

  defp frames(_stream, <<>>), do: []
  defp frames(stream, chunk), do: [frame(stream, chunk)]

  defp frame(stream, payload), do: [<<stream, byte_size(payload)::32>>, payload]
end
