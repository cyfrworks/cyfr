# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Test.Wire do
  @moduledoc """
  The client's end of the build wire, for the suite: it serves the real
  builds service (`Locus.Application.listener/1`, under the test's own
  supervisor, on a port the system chose), signs requests as CYFR does
  (`Cyfr.BuilderProtocol`), and speaks HTTP/1.1 to it over a plain socket,
  so a test can read an answer's lines as they arrive and leave in the
  middle of one. Nothing here is CYFR's client; it is a second, minimal
  reading of the same contract.
  """

  import ExUnit.Assertions

  alias Cyfr.BuilderProtocol

  @key :binary.copy(<<0x5A>>, 32)
  @athanor "ath_01a09fee-045b-770b-b745-a62792bb8798"

  @doc "The service key the suite's requests are signed from."
  def key, do: @key

  @doc "The athanor a request is for unless it names another."
  def athanor, do: @athanor

  @doc """
  Serve builds for the calling test: the service key installed, the
  listener started under the test's supervisor on a port of the system's
  choosing. Answers the port.
  """
  def serve! do
    previous = Application.fetch_env(:locus, :request_key)
    Application.put_env(:locus, :request_key, BuilderProtocol.request_key(@key))

    ExUnit.Callbacks.on_exit(fn ->
      case previous do
        {:ok, key} -> Application.put_env(:locus, :request_key, key)
        :error -> Application.delete_env(:locus, :request_key)
      end
    end)

    server =
      ExUnit.Callbacks.start_supervised!(
        Locus.Application.listener(ip: {127, 0, 0, 1}, port: 0, startup_log: false)
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    port
  end

  @doc """
  A tincture build request whose `npm run build` is `script`: the smallest
  build a test can steer. `fields` replace the request's own.
  """
  def request(script, fields \\ %{}) do
    Map.merge(
      %{
        athanor_id: @athanor,
        language: :javascript,
        target_type: :tincture,
        resolve: false,
        deadline: System.system_time(:millisecond) + 120_000,
        sources: %{
          "package.json" =>
            Jason.encode!(%{name: "wire-probe", private: true, scripts: %{build: script}})
        }
      },
      fields
    )
  end

  @doc "The wire body of `request`."
  def body(request) do
    {:ok, body} = BuilderProtocol.encode_request(request)
    body
  end

  @doc "The `x-cyfr-auth` header of `body`. Options: `:key` (a service key), `:ts`, `:nonce`."
  def header(body, opts \\ []) do
    auth = %{
      ts: Keyword.get_lazy(opts, :ts, fn -> System.system_time(:millisecond) end),
      nonce: Keyword.get_lazy(opts, :nonce, &nonce/0)
    }

    request_key = BuilderProtocol.request_key(Keyword.get(opts, :key, @key))
    {:ok, header} = BuilderProtocol.request_header(request_key, auth, body)
    header
  end

  @doc "A nonce no other request used."
  def nonce, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

  @doc "Post a signed build request and read the whole answer: `{status, lines}`, each line read."
  def build(port, request, opts \\ []) do
    body = body(request)
    post(port, BuilderProtocol.route(:build), body, [{"x-cyfr-auth", header(body, opts)}])
  end

  @doc "Post `body` to `path` and read the whole answer: `{status, lines}`, each line read."
  def post(port, path, body, headers \\ [], method \\ "POST") do
    conn = open(port, path, body, headers, method)
    {status, conn} = status(conn)
    {lines, conn} = rest(conn, [])
    close(conn)
    {status, lines}
  end

  @doc "Send a request and answer the connection, nothing of the answer read yet."
  def open(port, path, body, headers \\ [], method \\ "POST") do
    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :raw], 5_000)

    head =
      [{"host", "127.0.0.1:#{port}"}, {"content-length", Integer.to_string(byte_size(body))}]
      |> Kernel.++(headers)
      |> Enum.map(fn {name, value} -> [name, ": ", value, "\r\n"] end)

    :ok = :gen_tcp.send(socket, ["#{method} #{path} HTTP/1.1\r\n", head, "\r\n", body])
    %{socket: socket, buffer: "", framing: nil, lines: ""}
  end

  @doc "Send raw bytes as a request, for what `open/5` would never write."
  def open_raw(port, bytes) do
    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :raw], 5_000)

    :ok = :gen_tcp.send(socket, bytes)
    %{socket: socket, buffer: "", framing: nil, lines: ""}
  end

  @doc "The answer's status, its headers read past."
  def status(conn, timeout \\ 30_000) do
    {status, headers, conn} = head(conn, timeout)

    framing =
      cond do
        String.downcase(headers["transfer-encoding"] || "") == "chunked" -> :chunked
        length = headers["content-length"] -> {:length, String.to_integer(length)}
        true -> :until_close
      end

    {status, %{conn | framing: framing}}
  end

  @doc "The next line of the answer, read, or `:eof` when the answer is over."
  def line(conn, timeout \\ 30_000) do
    case String.split(conn.lines, "\n", parts: 2) do
      [line, rest] ->
        assert {:ok, read} = BuilderProtocol.read_line(line), "unreadable line: #{line}"
        {read, %{conn | lines: rest}}

      [_partial] ->
        case data(conn, timeout) do
          {:ok, bytes, conn} -> line(%{conn | lines: conn.lines <> bytes}, timeout)
          {:eof, conn} -> {:eof, conn}
        end
    end
  end

  @doc "Close the connection, as a client that left."
  def close(%{socket: socket}), do: :gen_tcp.close(socket)

  defp rest(conn, lines) do
    case line(conn) do
      {:eof, conn} ->
        assert conn.lines == "", "the answer ends in a partial line: #{inspect(conn.lines)}"
        {Enum.reverse(lines), conn}

      {line, conn} ->
        rest(conn, [line | lines])
    end
  end

  defp head(conn, timeout) do
    case :erlang.decode_packet(:http_bin, conn.buffer, []) do
      {:ok, {:http_response, _version, status, _reason}, rest} ->
        headers(%{conn | buffer: rest}, status, %{}, timeout)

      {:more, _} ->
        head(more!(conn, timeout), timeout)
    end
  end

  defp headers(conn, status, acc, timeout) do
    case :erlang.decode_packet(:httph_bin, conn.buffer, []) do
      {:ok, {:http_header, _, name, _, value}, rest} ->
        name = name |> to_string() |> String.downcase()
        headers(%{conn | buffer: rest}, status, Map.put(acc, name, value), timeout)

      {:ok, :http_eoh, rest} ->
        {status, acc, %{conn | buffer: rest}}

      {:more, _} ->
        headers(more!(conn, timeout), status, acc, timeout)
    end
  end

  # The next bytes of the answer's body, whatever its framing.
  defp data(%{framing: :chunked} = conn, timeout) do
    case String.split(conn.buffer, "\r\n", parts: 2) do
      [size, rest] ->
        case Integer.parse(size, 16) do
          {0, _} ->
            {:eof, conn}

          {bytes, _} when byte_size(rest) >= bytes + 2 ->
            <<chunk::binary-size(^bytes), "\r\n", rest::binary>> = rest
            {:ok, chunk, %{conn | buffer: rest}}

          {_bytes, _} ->
            data(more!(conn, timeout), timeout)
        end

      [_partial] ->
        data(more!(conn, timeout), timeout)
    end
  end

  defp data(%{framing: {:length, 0}} = conn, _timeout), do: {:eof, conn}

  defp data(%{framing: {:length, left}, buffer: ""} = conn, timeout) when left > 0,
    do: data(more!(conn, timeout), timeout)

  defp data(%{framing: {:length, left}, buffer: buffer} = conn, _timeout) do
    taken = min(left, byte_size(buffer))
    <<bytes::binary-size(^taken), rest::binary>> = buffer
    {:ok, bytes, %{conn | buffer: rest, framing: {:length, left - taken}}}
  end

  defp data(%{framing: :until_close, buffer: ""} = conn, timeout) do
    case :gen_tcp.recv(conn.socket, 0, timeout) do
      {:ok, bytes} -> {:ok, bytes, conn}
      {:error, :closed} -> {:eof, conn}
    end
  end

  defp data(%{framing: :until_close, buffer: buffer} = conn, _timeout),
    do: {:ok, buffer, %{conn | buffer: ""}}

  defp more!(conn, timeout) do
    case :gen_tcp.recv(conn.socket, 0, timeout) do
      {:ok, bytes} -> %{conn | buffer: conn.buffer <> bytes}
      {:error, reason} -> flunk("the answer ended early: #{inspect(reason)}")
    end
  end
end
