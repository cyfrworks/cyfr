# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Test.FakeSpawner do
  @moduledoc """
  The far end of a `Locus.Spawner` channel, standing in for cyfr-spawn: it
  answers a spawn by running the command on this machine as the test's own
  user and acting as its relay — it dials the request's attach socket,
  presents the token, reads stdin frames, and sends the command's stderr as
  it arrives and its stdout at exit — then reports `exited` and `released`.
  A `release` kills the command. It isolates nothing; it exercises the
  client's side of the protocol.

  Modes, set with `mode/2`:
  - `:normal`
  - `:capacity` — every spawn is refused with `capacity`
  - `:report_first` — `exited` and `released` are sent before the relay dials
  """

  use GenServer

  @stream_stdin 0
  @stream_stdout 1
  @stream_stderr 2
  @stream_attach 3

  @doc "Starts a fake and answers `{fake, client_channel}`, the `:socket` to hand `Locus.Spawner`."
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

  @doc "A private directory short enough for a unix socket path."
  def short_tmp_dir do
    dir = Path.join("/tmp", "lsp-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    dir
  end

  def mode(fake, mode), do: GenServer.call(fake, {:mode, mode})

  @doc "Every request received so far, decoded, oldest first."
  def requests(fake), do: GenServer.call(fake, :requests)

  @doc "Closes the channel, as cyfr-spawn exiting would."
  def close(fake), do: GenServer.call(fake, :close)

  @impl true
  def init(channel) do
    fake = self()
    spawn_link(fn -> read(channel, fake) end)
    {:ok, %{channel: channel, buffer: "", mode: :normal, requests: [], spawns: %{}, next: 0}}
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

  def handle_info({:send, message}, state) do
    :socket.send(state.channel, [Jason.encode!(Map.put(message, :v, 1)), ?\n])
    {:noreply, state}
  end

  def handle_info({:running, spawn_id, os_pid}, state),
    do: {:noreply, put_in(state.spawns[spawn_id], os_pid)}

  def handle_info(_message, state), do: {:noreply, state}

  defp handle_request(%{"type" => "spawn", "id" => id}, %{mode: :capacity} = state) do
    send(self(), {:send, %{type: "error", id: id, code: "capacity"}})
    state
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

  defp handle_request(%{"type" => "release", "spawn_id" => spawn_id}, state) do
    case state.spawns do
      %{^spawn_id => os_pid} when is_integer(os_pid) -> System.cmd("kill", ["-9", "#{os_pid}"])
      _ -> :ok
    end

    state
  end

  defp handle_request(_request, state), do: state

  defp relay(fake, spawn_id, request, mode) do
    dir = short_tmp_dir()
    input = Path.join(dir, "stdin")
    output = Path.join(dir, "stdout")

    {:ok, conn} =
      :gen_tcp.connect({:local, request["attach"]["path"]}, 0, [
        :binary,
        active: false,
        packet: :raw
      ])

    :ok = :gen_tcp.send(conn, frame(@stream_attach, request["attach"]["token"]))
    File.write!(input, read_stdin(conn, []))

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
    status = pump(port, conn)
    stdout = File.read!(output)
    exited = %{type: "exited", spawn_id: spawn_id, code: status, signal: nil}

    exited =
      if status == 137, do: %{exited | code: nil, signal: "SIGKILL"}, else: exited

    if mode == :report_first do
      send(fake, {:send, exited})
      send(fake, {:send, %{type: "released", spawn_id: spawn_id}})
      Process.sleep(200)
    end

    :gen_tcp.send(conn, [
      frames(@stream_stdout, stdout),
      frame(@stream_stdout, ""),
      frame(@stream_stderr, "")
    ])

    :gen_tcp.close(conn)
    File.rm_rf!(dir)

    unless mode == :report_first do
      send(fake, {:send, exited})
      send(fake, {:send, %{type: "released", spawn_id: spawn_id}})
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

  defp pump(port, conn) do
    receive do
      {^port, {:data, data}} ->
        :gen_tcp.send(conn, frames(@stream_stderr, data))
        pump(port, conn)

      {^port, {:exit_status, status}} ->
        status
    end
  end

  defp frames(stream, <<chunk::binary-size(65_536), rest::binary>>),
    do: [frame(stream, chunk) | frames(stream, rest)]

  defp frames(_stream, <<>>), do: []
  defp frames(stream, chunk), do: [frame(stream, chunk)]

  defp frame(stream, payload), do: [<<stream, byte_size(payload)::32>>, payload]
end
