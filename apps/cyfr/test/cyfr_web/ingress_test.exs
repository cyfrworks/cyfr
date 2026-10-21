# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.IngressTest do
  @moduledoc """
  The endpoint's two listeners, served by `CyfrWeb.Ingress` as Phoenix
  starts them, and the ingress each tags its requests with: the boundary,
  which no header a client sends can choose.

  Both listeners run here on ports of the system's choosing, under an
  endpoint of this test whose plug answers what the request carries and
  whose socket answers what a transport's `connect_info` carries, so the
  tag is read where every reader reads it: `Sanctum.ClientIp.ingress/1` on
  plain HTTP, and `Sanctum.ClientIp.ingress_from_connect_info/1` on the
  WebSocket upgrade and on LiveView's long-poll transport. On each, a
  forged, duplicated or missing tag reads as the listener that accepted
  the request: nothing that reaches the proxy listener is `:loopback`, and
  nothing that reaches the loopback listener is `:proxy`. The client
  address each resolves follows the same boundary, and a request the
  proxy listener accepted names itself by the home's `https` address.
  """

  # The endpoint's configuration, the proxy trust and a registered
  # observer are global.
  use ExUnit.Case, async: false

  alias Sanctum.ClientIp

  @observer __MODULE__.Observer

  defmodule Socket do
    @moduledoc false
    # Tells the test what a transport's connect carried.
    use Phoenix.Socket

    @impl true
    def connect(_params, socket, connect_info) do
      send(CyfrWeb.IngressTest.Observer, {:connected, connect_info})
      {:ok, socket}
    end

    @impl true
    def id(_socket), do: nil
  end

  defmodule Endpoint do
    @moduledoc false
    use Phoenix.Endpoint, otp_app: :cyfr

    socket "/live", CyfrWeb.IngressTest.Socket,
      websocket: [connect_info: [:peer_data, :x_headers]],
      longpoll: [connect_info: [:peer_data, :x_headers]]

    plug :answer

    # What the request arrived as, in JSON.
    def answer(conn, _opts) do
      body =
        Jason.encode!(%{
          ingress: ClientIp.ingress(conn),
          tags: for({"x-cyfr-ingress", tag} <- conn.req_headers, do: tag),
          client_ip: ClientIp.resolve(conn),
          url: Plug.Conn.request_url(conn)
        })

      Plug.Conn.send_resp(conn, 200, body)
    end
  end

  @loopback {127, 0, 0, 1}

  setup do
    Process.register(self(), @observer)
    trust = Application.fetch_env(:sanctum, :proxy_trust)

    on_exit(fn ->
      Application.delete_env(:cyfr, Endpoint)

      case trust do
        {:ok, value} -> Application.put_env(:sanctum, :proxy_trust, value)
        :error -> Application.delete_env(:sanctum, :proxy_trust)
      end
    end)

    # The test's client connects from 127.0.0.1, which the trust names as
    # the proxy, as compose names Caddy's and Tailscale's addresses.
    Application.put_env(:sanctum, :proxy_trust, {:cidrs, ["127.0.0.1"]})

    Application.put_env(:cyfr, Endpoint,
      adapter: CyfrWeb.Ingress,
      http: [ip: @loopback, port: 0, startup_log: false],
      proxy: [ip: @loopback, port: 0],
      secret_key_base: String.duplicate("ingress-test-", 6),
      pubsub_server: Cyfr.PubSub,
      server: true
    )

    start_supervised!(Endpoint)
    sessions = longpoll_sessions()
    on_exit(fn -> stop_sessions_since(sessions) end)

    {:ok, ports: ports(Endpoint)}
  end

  # Each listener's port: the loopback listener is Phoenix's own
  # `{endpoint, :http}` child, the proxy listener the one server under
  # `CyfrWeb.Ingress.Proxy`.
  defp ports(endpoint) do
    children = Supervisor.which_children(endpoint)
    {_, loopback, _, _} = List.keyfind(children, {endpoint, :http}, 0)
    {_, proxy, _, _} = List.keyfind(children, CyfrWeb.Ingress.Proxy, 0)
    [{_, server, _, _}] = Supervisor.which_children(proxy)
    %{loopback: port(loopback), proxy: port(server)}
  end

  defp port(server) do
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    port
  end

  defp longpoll_sessions do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(Phoenix.Transports.LongPoll.Supervisor),
        is_pid(pid),
        do: pid
  end

  defp stop_sessions_since(before) do
    for pid <- longpoll_sessions() -- before,
        do: DynamicSupervisor.terminate_child(Phoenix.Transports.LongPoll.Supervisor, pid)
  end

  # The forged tags a client may send: none, one naming either listener,
  # two, and one in another case.
  @forgeries [
    [],
    [{"x-cyfr-ingress", "loopback"}],
    [{"x-cyfr-ingress", "proxy"}],
    [{"x-cyfr-ingress", "loopback"}, {"x-cyfr-ingress", "loopback"}],
    [{"X-Cyfr-Ingress", "loopback"}, {"x-cyfr-ingress", "proxy"}]
  ]

  defp request(port, method, path, headers) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 5_000)

    head =
      Enum.map_join(
        [{"host", "cyfr.tail.ts.net"} | headers],
        "",
        fn {name, value} -> "#{name}: #{value}\r\n" end
      )

    :ok = :gen_tcp.send(socket, "#{method} #{path} HTTP/1.1\r\n#{head}\r\n")
    socket
  end

  # The status line and body of the answer, read to the connection's close.
  defp answer(port, path, headers) do
    socket = request(port, "GET", path, [{"connection", "close"} | headers])
    response = read_to_close(socket, "")
    [head, body] = String.split(response, "\r\n\r\n", parts: 2)
    {head |> String.split("\r\n") |> hd(), body}
  end

  defp read_to_close(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, bytes} -> read_to_close(socket, acc <> bytes)
      {:error, :closed} -> acc
    end
  end

  # The status line of the answer to a WebSocket upgrade, on a connection
  # this closes once it is read.
  defp upgrade(port, headers) do
    socket =
      request(port, "GET", "/live/websocket?vsn=2.0.0", [
        {"connection", "upgrade"},
        {"upgrade", "websocket"},
        {"sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ=="},
        {"sec-websocket-version", "13"} | headers
      ])

    {:ok, bytes} = :gen_tcp.recv(socket, 0, 5_000)
    :ok = :gen_tcp.close(socket)
    bytes |> String.split("\r\n") |> hd()
  end

  defp connected do
    assert_receive {:connected, connect_info}, 5_000
    connect_info
  end

  describe "plain HTTP" do
    test "reads as the listener that accepted it, whatever tag the client sent", %{ports: ports} do
      for {listener, port} <- ports, forged <- @forgeries do
        assert {"HTTP/1.1 200 OK", body} = answer(port, "/", forged)
        tagged = Jason.decode!(body)

        assert tagged["ingress"] == Atom.to_string(listener), "#{listener}: #{inspect(forged)}"
        assert tagged["tags"] == [Atom.to_string(listener)], "#{listener}: #{inspect(forged)}"
      end
    end

    test "trusts a forwarded header on the proxy listener alone, from the trusted proxy alone",
         %{ports: ports} do
      forwarded = [{"x-forwarded-for", "198.51.100.7, 100.101.102.103"}]

      assert {_, body} = answer(ports.proxy, "/", forwarded)
      assert Jason.decode!(body)["client_ip"] == "100.101.102.103"

      assert {_, body} = answer(ports.loopback, "/", forwarded)
      assert Jason.decode!(body)["client_ip"] == "127.0.0.1"

      # A peer outside the trusted proxies is the client on either.
      Application.put_env(:sanctum, :proxy_trust, {:cidrs, ["172.16.234.3", "172.16.234.4"]})

      for {_listener, port} <- ports do
        assert {_, body} = answer(port, "/", forwarded)
        assert Jason.decode!(body)["client_ip"] == "127.0.0.1"
      end
    end

    test "on the proxy listener names itself by the home's https address", %{ports: ports} do
      assert {_, body} = answer(ports.proxy, "/auth/oidcc/callback?code=1", [])
      assert Jason.decode!(body)["url"] == "https://cyfr.tail.ts.net/auth/oidcc/callback?code=1"

      # The loopback listener's request is the plain HTTP its client
      # spoke, at the address its `Host` names.
      assert {_, body} = answer(ports.loopback, "/auth/oidcc/callback", [])
      assert Jason.decode!(body)["url"] == "http://cyfr.tail.ts.net/auth/oidcc/callback"
    end
  end

  describe "the WebSocket upgrade" do
    test "carries the listener's one tag into connect_info, whatever the client sent",
         %{ports: ports} do
      for {listener, port} <- ports, forged <- @forgeries do
        assert upgrade(port, forged) == "HTTP/1.1 101 Switching Protocols"
        info = connected()

        assert ClientIp.ingress_from_connect_info(info) == listener,
               "#{listener}: #{inspect(forged)}"

        assert for({"x-cyfr-ingress", tag} <- info.x_headers, do: tag) == [
                 Atom.to_string(listener)
               ]
      end
    end

    test "resolves the client as the conn does, on the socket path", %{ports: ports} do
      forwarded = [{"x-forwarded-for", "198.51.100.7, 100.101.102.103"}]

      upgrade(ports.proxy, forwarded)
      assert ClientIp.from_connect_info(connected()) == "100.101.102.103"

      upgrade(ports.loopback, [{"x-cyfr-ingress", "proxy"} | forwarded])
      assert ClientIp.from_connect_info(connected()) == "127.0.0.1"
    end
  end

  describe "the long-poll transport" do
    test "carries the listener's one tag into connect_info, whatever the client sent",
         %{ports: ports} do
      for {listener, port} <- ports, forged <- @forgeries do
        assert {"HTTP/1.1 200 OK", body} = answer(port, "/live/longpoll?vsn=2.0.0", forged)
        assert %{"status" => 410, "token" => _} = Jason.decode!(body)
        info = connected()

        assert ClientIp.ingress_from_connect_info(info) == listener,
               "#{listener}: #{inspect(forged)}"

        assert ClientIp.from_connect_info(info) == "127.0.0.1"
      end
    end
  end

  describe "the listeners" do
    test "the proxy listener exists only when the endpoint is configured with one" do
      config = [otp_app: :cyfr, http: [ip: @loopback, port: 0]]

      assert [%{id: {Endpoint, :http}}] = CyfrWeb.Ingress.child_specs(Endpoint, config)

      assert [%{id: {Endpoint, :http}}, %{id: CyfrWeb.Ingress.Proxy, type: :supervisor}] =
               CyfrWeb.Ingress.child_specs(
                 Endpoint,
                 config ++ [proxy: [ip: @loopback, port: 0]]
               )
    end

    test "the proxy listener takes the loopback listener's options but its address and port" do
      http = [
        ip: @loopback,
        port: 4000,
        thousand_island_options: [shutdown_timeout: 30_000, read_timeout: 60_000],
        http_2_options: [enabled: false]
      ]

      [_loopback, %{start: {Supervisor, :start_link, [[server], _opts]}}] =
        CyfrWeb.Ingress.child_specs(Endpoint,
          otp_app: :cyfr,
          http: http,
          proxy: [ip: {172, 16, 234, 2}, port: 4001]
        )

      %{start: {Bandit, :start_link, [options]}} = server

      assert options[:ip] == {172, 16, 234, 2}
      assert options[:port] == 4001
      assert options[:thousand_island_options] == http[:thousand_island_options]
      assert options[:http_2_options] == [enabled: false]
      assert options[:plug] == {CyfrWeb.Ingress, {:proxy, Endpoint}}
    end

    test "an https listener is refused: the endpoint serves no TLS of its own" do
      assert_raise ArgumentError, ~r/serves no TLS listener/, fn ->
        CyfrWeb.Ingress.child_specs(Endpoint,
          otp_app: :cyfr,
          http: [ip: @loopback, port: 0],
          https: [port: 4443]
        )
      end
    end
  end
end
