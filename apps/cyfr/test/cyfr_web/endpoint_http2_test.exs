# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.EndpointHTTP2Test do
  @moduledoc """
  The endpoint serves HTTP/1.1 alone. A connection that opens with the
  HTTP/2 prior-knowledge preface (h2c) is closed unanswered, never
  answered with an HTTP/2 SETTINGS frame, while on the same listener an
  HTTP/1.1 request is answered and the LiveView socket's WebSocket
  upgrades.

  The suite's endpoint runs without a server, so the listener here is the
  one Phoenix would start for it: the endpoint's adapter's child spec over
  the `http:` options the endpoint is configured with, on a port of its
  own. Under test those options are `config/config.exs`'s base merged
  under `config/test.exs`, since the prod block of `config/runtime.exs`
  does not run here: the wire case proves the base. The release's
  endpoint, `config/config.exs` read for prod with `config/runtime.exs`
  evaluated over it as a release evaluates it, keeps the same setting.
  """

  # The release case sets the operating system's environment.
  use ExUnit.Case, async: false

  @endpoint CyfrWeb.Endpoint
  @root Path.expand("../../../..", __DIR__)

  # The HTTP/2 connection preface a client with prior knowledge sends
  # (RFC 9113 §3.4), then an empty SETTINGS frame: length 0, type 4, no
  # flags, stream 0.
  @h2c_preface "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
  @empty_settings <<0::24, 4, 0, 0::32>>

  @health "GET /api/health HTTP/1.1\r\nhost: localhost\r\nconnection: close\r\n\r\n"
  @websocket "GET /live/websocket?vsn=2.0.0 HTTP/1.1\r\nhost: localhost\r\n" <>
               "connection: upgrade\r\nupgrade: websocket\r\n" <>
               "sec-websocket-key: dGhlIHNhbXBsZSBub25jZQ==\r\nsec-websocket-version: 13\r\n\r\n"

  # The endpoint's server as Phoenix starts it, on a port of its own.
  defp start_server! do
    http = Keyword.put(@endpoint.config(:http), :port, 0)

    [spec] =
      @endpoint.config(:adapter).child_specs(@endpoint,
        otp_app: @endpoint.config(:otp_app),
        code_reloader: @endpoint.config(:code_reloader),
        http: http
      )

    {:ok, address} = ThousandIsland.listener_info(start_supervised!(spec))
    address
  end

  defp connect({ip, port}) do
    {:ok, socket} = :gen_tcp.connect(ip, port, [:binary, active: false], 5_000)
    socket
  end

  # What the listener sends first to a connection that opens with the
  # HTTP/2 preface: its first bytes, or `:closed` when it closes the
  # connection having sent none. A listener that reads the preface alone
  # and closes leaves the SETTINGS frame unread, which resets the
  # connection.
  defp h2c_answer(address) do
    socket = connect(address)
    :ok = :gen_tcp.send(socket, @h2c_preface <> @empty_settings)

    answer =
      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, bytes} -> bytes
        {:error, reason} when reason in [:closed, :econnreset] -> :closed
        {:error, :timeout} -> flunk("the listener neither answered the h2c preface nor closed")
      end

    :ok = :gen_tcp.close(socket)
    answer
  end

  defp settings_frame?(<<_length::24, 4, _flags, _stream::32, _rest::binary>>), do: true
  defp settings_frame?(_answer), do: false

  # The status line and body of the answer to `request`, read to the
  # connection's close.
  defp http1_answer(address, request) do
    socket = connect(address)
    :ok = :gen_tcp.send(socket, request)
    response = read_to_close(socket, "", System.monotonic_time(:millisecond) + 5_000)
    :ok = :gen_tcp.close(socket)
    [head, body] = String.split(response, "\r\n\r\n", parts: 2)
    {head |> String.split("\r\n") |> hd(), body}
  end

  defp read_to_close(socket, acc, deadline) do
    case :gen_tcp.recv(socket, 0, max(deadline - System.monotonic_time(:millisecond), 0)) do
      {:ok, bytes} -> read_to_close(socket, acc <> bytes, deadline)
      {:error, :closed} -> acc
      {:error, :timeout} -> flunk("the listener did not close after its answer: #{inspect(acc)}")
    end
  end

  # The status line the listener answers `request` with, on a connection
  # it keeps open after it.
  defp status_line(address, request) do
    socket = connect(address)
    :ok = :gen_tcp.send(socket, request)
    head = read_head(socket, "", System.monotonic_time(:millisecond) + 5_000)
    :ok = :gen_tcp.close(socket)
    head |> String.split("\r\n") |> hd()
  end

  defp read_head(socket, acc, deadline) do
    if String.contains?(acc, "\r\n\r\n") do
      acc
    else
      case :gen_tcp.recv(socket, 0, max(deadline - System.monotonic_time(:millisecond), 0)) do
        {:ok, bytes} -> read_head(socket, acc <> bytes, deadline)
        {:error, reason} -> flunk("no answer head (#{inspect(reason)}): #{inspect(acc)}")
      end
    end
  end

  test "the endpoint's listener closes an h2c connection unanswered and serves HTTP/1.1" do
    address = start_server!()

    # The listener is the endpoint's own: it answers HTTP/1.1, and the
    # LiveView socket upgrades to a WebSocket over it.
    assert {"HTTP/1.1 200 OK", body} = http1_answer(address, @health)
    assert Jason.decode!(body) == %{"status" => "ok", "service" => "emissary"}
    assert status_line(address, @websocket) == "HTTP/1.1 101 Switching Protocols"

    answer = h2c_answer(address)

    refute settings_frame?(answer),
           "the endpoint answered the h2c preface with an HTTP/2 SETTINGS frame: " <>
             inspect(answer, limit: 64)

    assert answer == :closed
  end

  test "the release's endpoint, and every environment's, serves HTTP/1.1 alone" do
    enabled = [:cyfr, @endpoint, :http, :http_2_options, :enabled]

    for env <- [:dev, :test] do
      config = Config.Reader.read!(Path.join(@root, "config/config.exs"), env: env)
      assert get_in(config, enabled) == false, "the #{env} endpoint serves HTTP/2"
    end

    release_env!()

    runtime =
      Config.Reader.read!(Path.join(@root, "config/runtime.exs"), env: :prod, imports: :disabled)

    release =
      Config.Reader.merge(
        Config.Reader.read!(Path.join(@root, "config/config.exs"), env: :prod),
        runtime
      )

    # The runtime's `http:` is merged over the base, not in its place: its
    # read timeout and the base's drain both stand.
    timeouts = [:cyfr, @endpoint, :http, :thousand_island_options]
    assert get_in(runtime, timeouts ++ [:read_timeout]) == 60_000
    assert get_in(release, timeouts ++ [:read_timeout]) == 60_000
    assert get_in(release, timeouts ++ [:shutdown_timeout]) == 30_000

    assert get_in(release, enabled) == false, "the release's endpoint serves HTTP/2"
  end

  # The environment a release boots under, `.env` files read from an
  # empty RELEASE_ROOT, restored after the case.
  defp release_env! do
    dir =
      Path.join(System.tmp_dir!(), "cyfr-endpoint-http2-#{System.unique_integer([:positive])}")

    vars = %{
      "CYFR_SECRET_KEY_BASE" => Base.encode64(:crypto.strong_rand_bytes(48)),
      "RELEASE_NAME" => "cyfr",
      "RELEASE_ROOT" => dir,
      "CYFR_DATABASE" => nil
    }

    previous = Map.new(vars, fn {name, _value} -> {name, System.get_env(name)} end)

    on_exit(fn ->
      Enum.each(previous, &put_os_env/1)
      File.rm_rf!(dir)
    end)

    File.mkdir_p!(dir)
    Enum.each(vars, &put_os_env/1)
  end

  defp put_os_env({name, nil}), do: System.delete_env(name)
  defp put_os_env({name, value}), do: System.put_env(name, value)
end
