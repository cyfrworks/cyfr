# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.Plugs.ApiSecurityHeadersTest do
  @moduledoc """
  The endpoint's HSTS, through its real listeners.

  A tailnet home's proxy listener carries the endpoint's one HSTS value on
  every response it sends whose `Host` is not a loopback name: a success,
  an error and a refusal made before any pipeline alike. The loopback
  listener never carries it, and neither does a public home's proxy
  listener, whose HSTS is Caddy's, nor a local home's listener.

  Both listeners run here as Phoenix would start them for the running
  endpoint (`CyfrWeb.Ingress.child_specs/2`), on ports of their own; the
  suite's endpoint serves none.
  """

  # Sets the reach's HSTS, which is global.
  use ExUnit.Case, async: false

  @endpoint CyfrWeb.Endpoint
  @hsts "max-age=63072000; includeSubDomains"

  setup do
    original = Application.fetch_env!(:cyfr, :hsts)
    on_exit(fn -> Application.put_env(:cyfr, :hsts, original) end)

    Application.put_env(:cyfr, :hsts, :endpoint_on_proxy)

    address = [ip: {127, 0, 0, 1}, port: 0]

    [loopback, proxy] =
      @endpoint.config(:adapter).child_specs(@endpoint,
        otp_app: @endpoint.config(:otp_app),
        code_reloader: @endpoint.config(:code_reloader),
        http: Keyword.merge(@endpoint.config(:http), address ++ [startup_log: false]),
        proxy: address
      )

    loopback = start_supervised!(loopback)
    [{_, proxy, _, _}] = proxy |> start_supervised!() |> Supervisor.which_children()

    {:ok, ports: %{loopback: port(loopback), proxy: port(proxy)}}
  end

  defp port(server) do
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    port
  end

  # A success, an error and a refusal: the health check, a route that does
  # not exist, and a long-poll POST that declares no length, which the
  # endpoint refuses before any pipeline, before it reads the body.
  @answers [
    {"GET /api/health", 200},
    {"GET /api/no-such-route", 404},
    {"POST /live/longpoll", 411}
  ]

  # The status and the HSTS values of the answer to `request` for `host`.
  defp answer(port, request, host) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 5_000)

    :ok =
      :gen_tcp.send(
        socket,
        "#{request} HTTP/1.1\r\nhost: #{host}\r\nconnection: close\r\n\r\n"
      )

    response = read_to_close(socket, "")
    [head | _body] = String.split(response, "\r\n\r\n", parts: 2)
    [status_line | headers] = String.split(head, "\r\n")
    [_version, status | _reason] = String.split(status_line, " ", parts: 3)

    hsts =
      for line <- headers,
          [name, value] = String.split(line, ":", parts: 2),
          String.downcase(name) == "strict-transport-security",
          do: String.trim(value)

    {String.to_integer(status), hsts}
  end

  defp read_to_close(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, bytes} -> read_to_close(socket, acc <> bytes)
      {:error, :closed} -> acc
    end
  end

  @tailnet_host "cyfr.tail0123.ts.net"
  @loopback_hosts [
    "localhost",
    "LOCALHOST",
    "phone.localhost",
    "a.b.Localhost",
    "127.0.0.1",
    "[::1]",
    "localhost:4100"
  ]

  test "a tailnet home's proxy listener sends the endpoint's HSTS on success, error and refusal",
       %{ports: ports} do
    for {request, status} <- @answers, host <- [@tailnet_host, @tailnet_host <> ":443"] do
      assert answer(ports.proxy, request, host) == {status, [@hsts]}, "#{request} for #{host}"
    end
  end

  test "a loopback host gets none on the proxy listener", %{ports: ports} do
    for {request, status} <- @answers, host <- @loopback_hosts do
      assert answer(ports.proxy, request, host) == {status, []}, "#{request} for #{host}"
    end
  end

  test "the loopback listener never sends it, whatever the host", %{ports: ports} do
    for {request, status} <- @answers, host <- [@tailnet_host | @loopback_hosts] do
      assert answer(ports.loopback, request, host) == {status, []}, "#{request} for #{host}"
    end
  end

  test "a public home's proxy listener leaves HSTS to Caddy, and a local home sends none",
       %{ports: ports} do
    for reach <- [:caddy, :none], {request, status} <- @answers do
      Application.put_env(:cyfr, :hsts, reach)
      assert answer(ports.proxy, request, @tailnet_host) == {status, []}, "#{reach}: #{request}"
    end
  end

  test "outside a listener, the plug's decision sends none: no listener accepted the request" do
    conn =
      Plug.Test.conn(:get, "https://#{@tailnet_host}/api/health")
      |> CyfrWeb.Plugs.ApiSecurityHeaders.maybe_hsts()

    assert Plug.Conn.get_resp_header(conn, "strict-transport-security") == []

    tagged =
      Plug.Test.conn(:get, "/api/health")
      |> Map.put(:host, @tailnet_host)
      |> Sanctum.ClientIp.put_ingress(:proxy)
      |> CyfrWeb.Plugs.ApiSecurityHeaders.maybe_hsts()

    assert Plug.Conn.get_resp_header(tagged, "strict-transport-security") == [@hsts]
  end
end
