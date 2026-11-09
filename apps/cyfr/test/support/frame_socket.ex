# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.FrameSocket do
  @moduledoc """
  A frame's stream connection (`Emissary.Web.FrameSocket`) for tests,
  driven in a process of its own as a server drives a WebSocket handler:
  each text the test sends goes to `handle_in/2`, every other message the
  process receives to `handle_info/2`, so forwarders, timers and bus
  announcements reach it as they would. Every message the connection
  pushes reaches the test, decoded, as `{:socket, pid, message}`, and its
  close as `{:socket_closed, pid, code, reason}`.

  Beside it, `ws_open/3`, `ws_send/2` and `ws_recv/2`: a WebSocket client
  over a raw TCP socket, as far as a case over a real listener needs one.
  """

  import ExUnit.Assertions

  alias Emissary.Web.FrameSocket
  alias Prima.TinctureWire

  @doc """
  A connection opened on `path` (`:shared` or `{:canvas, frame_id}`),
  answering the calling process; it ends with it. Its upgrade's request id
  is `request_id`, a fresh one by default.
  """
  @spec connect(FrameSocket.path(), String.t()) :: pid()
  def connect(path \\ :shared, request_id \\ Prima.UUID7.request_id()) do
    test = self()

    pid =
      spawn_link(fn ->
        {:ok, state} =
          FrameSocket.init(%{path: path, client_ip: "127.0.0.1", request_id: request_id})

        loop(test, state)
      end)

    ExUnit.Callbacks.on_exit(fn -> stop(pid) end)
    pid
  end

  @doc "Send `message` (a map, encoded as JSON, or a text as it is) as one text frame."
  @spec send_text(pid(), map() | String.t()) :: :ok
  def send_text(pid, message) when is_map(message), do: send_text(pid, Jason.encode!(message))

  def send_text(pid, text) when is_binary(text) do
    send(pid, {__MODULE__, :in, {text, opcode: :text}})
    :ok
  end

  @doc "Send a binary frame."
  @spec send_binary(pid(), binary()) :: :ok
  def send_binary(pid, data) do
    send(pid, {__MODULE__, :in, {data, opcode: :binary}})
    :ok
  end

  @doc "Subscribe `sub` to `stream` with `subject` under `bearer`."
  @spec subscribe(pid(), pos_integer(), String.t(), String.t(), String.t() | nil) :: :ok
  def subscribe(pid, sub, bearer, stream, subject \\ nil),
    do: send_text(pid, TinctureWire.subscribe(sub, bearer, stream, subject))

  @doc "Unsubscribe `sub`."
  @spec unsubscribe(pid(), pos_integer()) :: :ok
  def unsubscribe(pid, sub), do: send_text(pid, TinctureWire.unsubscribe(sub))

  @doc "The connection's state, as the handler holds it now."
  @spec state(pid()) :: map()
  def state(pid) do
    ref = make_ref()
    send(pid, {__MODULE__, :state, self(), ref})

    receive do
      {^ref, state} -> state
    after
      5_000 -> flunk("the connection did not answer")
    end
  end

  @doc "Change the connection's state with `fun`, as a case's setup needs."
  @spec update(pid(), (map() -> map())) :: :ok
  def update(pid, fun) do
    send(pid, {__MODULE__, :update, fun})
    :ok
  end

  @doc "Stop the connection, as a closed socket does."
  @spec stop(pid()) :: :ok
  def stop(pid) do
    if Process.alive?(pid) do
      monitor = Process.monitor(pid)
      Process.unlink(pid)
      Process.exit(pid, :shutdown)

      receive do
        {:DOWN, ^monitor, :process, _pid, _reason} -> :ok
      after
        5_000 -> flunk("the connection did not stop")
      end
    end

    :ok
  end

  defp loop(test, state) do
    receive do
      {__MODULE__, :in, frame} ->
        result(test, FrameSocket.handle_in(frame, state))

      {__MODULE__, :state, from, ref} ->
        send(from, {ref, state})
        loop(test, state)

      {__MODULE__, :update, fun} ->
        loop(test, fun.(state))

      message ->
        result(test, FrameSocket.handle_info(message, state))
    end
  end

  defp result(test, {:ok, state}), do: loop(test, state)

  defp result(test, {:push, frames, state}) do
    pushed(test, frames)
    loop(test, state)
  end

  defp result(test, {:stop, _reason, {code, reason}, state}) do
    FrameSocket.terminate(:normal, state)
    send(test, {:socket_closed, self(), code, reason})
  end

  defp result(test, {:stop, _reason, {code, reason}, frames, state}) do
    pushed(test, frames)
    result(test, {:stop, :normal, {code, reason}, state})
  end

  defp pushed(test, frames) do
    for frame <- List.wrap(frames) do
      case frame do
        {:text, json} -> send(test, {:socket, self(), Jason.decode!(json)})
        {:ping, _data} -> send(test, {:socket_ping, self()})
      end
    end
  end

  # ---- a WebSocket client over a raw TCP socket ---------------------------------

  @doc """
  Open a WebSocket to `path` on the listener at `port`, answered 101,
  sending `headers` beside the upgrade's own: by default a sandboxed
  frame's `Origin: null`.
  """
  @spec ws_open(:inet.port_number(), String.t(), [{String.t(), String.t()}]) ::
          :gen_tcp.socket()
  def ws_open(port, path, headers \\ [{"Origin", "null"}]) do
    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :raw], 5_000)

    key = Base.encode64(:crypto.strong_rand_bytes(16))

    :ok =
      :gen_tcp.send(socket, [
        "GET #{path} HTTP/1.1\r\n",
        "Host: localhost\r\n",
        Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end),
        "Upgrade: websocket\r\n",
        "Connection: Upgrade\r\n",
        "Sec-WebSocket-Key: #{key}\r\n",
        "Sec-WebSocket-Version: 13\r\n\r\n"
      ])

    assert headers(socket, "") =~ ~r{\AHTTP/1\.1 101}
    socket
  end

  defp headers(socket, received) do
    if String.contains?(received, "\r\n\r\n") do
      received
    else
      {:ok, more} = :gen_tcp.recv(socket, 0, 5_000)
      headers(socket, received <> more)
    end
  end

  @doc "Send `payload` as one masked text frame, as a client sends it."
  @spec ws_send(:gen_tcp.socket(), binary()) :: :ok | {:error, term()}
  def ws_send(socket, payload) do
    mask = :crypto.strong_rand_bytes(4)
    length = byte_size(payload)

    header =
      cond do
        length < 126 -> <<1::1, 0::3, 1::4, 1::1, length::7>>
        length < 65_536 -> <<1::1, 0::3, 1::4, 1::1, 126::7, length::16>>
        true -> <<1::1, 0::3, 1::4, 1::1, 127::7, length::64>>
      end

    :gen_tcp.send(socket, [header, mask, masked(payload, mask)])
  end

  defp masked(payload, mask) do
    keys = :binary.bin_to_list(mask)

    payload
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.map(fn {byte, i} -> Bitwise.bxor(byte, Enum.at(keys, rem(i, 4))) end)
    |> :binary.list_to_bin()
  end

  @doc """
  One unmasked frame, as the server sends it: its opcode and payload, all
  of it read before `deadline` (monotonic milliseconds).
  """
  @spec ws_recv(:gen_tcp.socket(), integer()) :: {non_neg_integer(), binary()}
  def ws_recv(socket, deadline \\ System.monotonic_time(:millisecond) + 5_000) do
    <<_fin::1, _rsv::3, opcode::4, 0::1, short::7>> = bounded_recv(socket, 2, deadline)

    length =
      case short do
        126 ->
          <<extended::16>> = bounded_recv(socket, 2, deadline)
          extended

        127 ->
          <<extended::64>> = bounded_recv(socket, 8, deadline)
          extended

        short ->
          short
      end

    payload = if length > 0, do: bounded_recv(socket, length, deadline), else: ""
    {opcode, payload}
  end

  defp bounded_recv(socket, length, deadline) do
    left = max(deadline - System.monotonic_time(:millisecond), 0)
    assert {:ok, bytes} = :gen_tcp.recv(socket, length, left)
    bytes
  end
end
