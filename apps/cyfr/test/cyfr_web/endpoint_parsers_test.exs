# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.EndpointParsersTest do
  @moduledoc """
  No route takes a multipart body, so the endpoint parses none: a
  multipart request is refused 415 before any byte of its body is read,
  `/mcp` in JSON-RPC and every other route through `CyfrWeb.ApiError`,
  while every other body keeps its route's cap and the endpoint's 413.
  Reads are counted by a
  body source that reports each one, and a real connection that never
  sends its body is answered and closed.
  """

  # Every request here is refused in the endpoint, before any route runs:
  # nothing reaches the database or changes shared state.
  use ExUnit.Case, async: true

  import Phoenix.ConnTest, only: [assert_error_sent: 2]
  import Plug.Conn

  alias Prima.MCP.Message

  defmodule CountingBody do
    @moduledoc false
    # `Plug.Adapters.Test.Conn`, reporting every read of the request body
    # to the test process as `{:body_read, bytes}`. A refusal that reads
    # nothing of the body sends none.
    @behaviour Plug.Conn.Adapter

    alias Plug.Adapters.Test.Conn, as: Inner

    def wrap(%Plug.Conn{adapter: {Inner, state}} = conn),
      do: %{conn | adapter: {__MODULE__, state}}

    @impl true
    def read_req_body(state, opts) do
      {tag, data, state} = Inner.read_req_body(state, opts)
      send(state.owner, {:body_read, byte_size(data)})
      {tag, data, state}
    end

    @impl true
    defdelegate send_resp(state, status, headers, body), to: Inner
    @impl true
    defdelegate send_file(state, status, headers, path, offset, length), to: Inner
    @impl true
    defdelegate send_chunked(state, status, headers), to: Inner
    @impl true
    defdelegate chunk(state, body), to: Inner
    @impl true
    defdelegate inform(state, status, headers), to: Inner
    @impl true
    defdelegate upgrade(state, protocol, opts), to: Inner
    @impl true
    defdelegate push(state, path, headers), to: Inner
    @impl true
    defdelegate get_peer_data(state), to: Inner
    @impl true
    defdelegate get_sock_data(state), to: Inner
    @impl true
    defdelegate get_ssl_data(state), to: Inner
    @impl true
    defdelegate get_http_protocol(state), to: Inner
  end

  @multipart "multipart/form-data; boundary=r8"

  # The endpoint's own parser length: what a multipart body could cost
  # when the multipart parser read it.
  @upload_bytes 28_000_000

  # The refusal in `CyfrWeb.ApiError`'s shape.
  @refused %{
    "code" => "invalid_argument",
    "message" => "This endpoint takes no multipart bodies"
  }

  setup_all do
    {:ok, upload: :binary.copy(<<?x>>, @upload_bytes)}
  end

  defp request(method, url, body, content_type) do
    method
    |> Plug.Test.conn(url, body)
    |> put_req_header("content-type", content_type)
    |> put_req_header("accept", "application/json")
    |> CountingBody.wrap()
  end

  defp call(conn), do: CyfrWeb.Endpoint.call(conn, CyfrWeb.Endpoint.init([]))

  defp bytes_read(total \\ 0) do
    receive do
      {:body_read, bytes} -> bytes_read(total + bytes)
    after
      0 -> total
    end
  end

  defp assert_api_refusal(conn) do
    conn = call(conn)

    assert conn.halted
    assert conn.status == 415
    assert Jason.decode!(conn.resp_body) == @refused
    assert get_resp_header(conn, "connection") == ["close"]
  end

  defp assert_jsonrpc_refusal(conn) do
    conn = call(conn)

    assert conn.status == 415
    body = Jason.decode!(conn.resp_body)
    assert body["jsonrpc"] == "2.0"
    assert body["id"] == nil
    assert body["error"]["code"] == Message.error_code(:parse_error)
    assert get_resp_header(conn, "mcp-protocol-version") != []
    assert get_resp_header(conn, "connection") == ["close"]
  end

  # A route's path with each parameter and glob filled in.
  defp concrete(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", fn
      ":" <> _param -> "x"
      "*" <> _glob -> "x"
      segment -> segment
    end)
  end

  defp mcp?(path), do: match?(["mcp" | _], String.split(path, "/", trim: true))

  describe "the inventory" do
    test "no route takes a multipart body: each refuses one 415, reading none of it" do
      paths = CyfrWeb.Router.__routes__() |> Enum.map(& &1.path) |> Enum.uniq()

      # The sweep covers the routes the failure cases name.
      for path <- ["/hooks/:slug", "/directory/v1/genesis", "/restore", "/mcp"] do
        assert path in paths
      end

      for path <- paths, method <- [:post, :put, :patch, :delete] do
        conn = request(method, concrete(path), "--r8--", @multipart)

        if mcp?(path),
          do: assert_jsonrpc_refusal(conn),
          else: assert_api_refusal(conn)

        assert bytes_read() == 0, "#{method} #{path} read the multipart body"
      end
    end
  end

  describe "a multipart body" do
    test "of 28 MB to a webhook, the directory or the restore ingress is refused unread, " <>
           "however its path is spelled",
         %{upload: upload} do
      for url <- [
            "/hooks/wh_any",
            "http://www.example.com//hooks/wh_any",
            "/directory/v1/genesis",
            "/directory/v1/per_x/entries",
            "http://www.example.com//directory//v1/genesis",
            "/restore",
            "/restore/challenge",
            "http://www.example.com//restore"
          ] do
        assert_api_refusal(request(:post, url, upload, @multipart))
        assert bytes_read() == 0, "#{url} read the multipart body"
      end
    end

    test "to /mcp is refused 415 in JSON-RPC, -32700 with a null id, unread, its connection closed",
         %{upload: upload} do
      for url <- ["/mcp", "http://www.example.com//mcp"], method <- [:post, :delete] do
        assert_jsonrpc_refusal(request(method, url, upload, "multipart/mixed; boundary=r8"))
        assert bytes_read() == 0, "#{method} #{url} read the multipart body"
      end
    end

    test "to a route that only begins with /mcp's letters answers outside JSON-RPC" do
      assert_api_refusal(request(:post, "/mcp-servers", "--r8--", @multipart))
      assert bytes_read() == 0
    end
  end

  describe "every other body" do
    test "keeps its route's cap, read only up to it, and the endpoint's own 413" do
      directory_cap = Prima.Identity.max_entry_bytes()

      webhook_cap =
        Application.get_env(
          :cyfr,
          :webhook_max_body_bytes,
          Prima.Limits.default_max_request_size()
        )

      for {url, cap} <- [
            {"/directory/v1/genesis", directory_cap},
            {"http://www.example.com//directory/v1/genesis", directory_cap},
            {"/restore", directory_cap},
            {"/hooks/wh_any", webhook_cap}
          ] do
        body = ~s({"pad":") <> :binary.copy(<<?x>>, cap) <> ~s("})
        conn = request(:post, url, body, "application/json")

        {413, _headers, sent} = assert_error_sent(413, fn -> call(conn) end)

        # Rendered by the endpoint (`CyfrWeb.ErrorJSON`), as before.
        assert Jason.decode!(sent) == %{
                 "errors" => %{"detail" => Plug.Conn.Status.reason_phrase(413)}
               }

        assert bytes_read() == cap, "#{url} was not read to its cap of #{cap} bytes"
      end
    end
  end

  describe "on a real connection" do
    setup do
      {:ok, server} =
        start_supervised(
          {Bandit,
           plug: CyfrWeb.Endpoint, scheme: :http, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
      {:ok, port: port}
    end

    # Bandit waits 15 seconds for each read of a body it reads, so an
    # answer and a close well inside that mean no byte of the body was
    # awaited.
    @answered_within 5_000

    test "a multipart request is answered 415 from its headers alone, and its connection " <>
           "ends without its body",
         %{port: port} do
      for path <- ["/hooks/wh_any", "/directory/v1/genesis", "/restore", "/mcp"] do
        {:ok, socket} =
          :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :raw], 5_000)

        :ok =
          :gen_tcp.send(socket, [
            "POST #{path} HTTP/1.1\r\n",
            "host: localhost\r\n",
            "accept: application/json\r\n",
            "content-type: #{@multipart}\r\n",
            "content-length: #{@upload_bytes}\r\n\r\n"
          ])

        deadline = System.monotonic_time(:millisecond) + @answered_within
        response = until_closed(socket, "", deadline)

        assert response =~ ~r{\AHTTP/1\.1 415 }, "#{path} answered #{inspect(response)}"
        assert response =~ ~r{\r\nconnection: close\r\n}i

        if path == "/mcp",
          do: assert(response =~ ~s("jsonrpc":"2.0")),
          else: assert(response =~ ~s("message":"This endpoint takes no multipart bodies"))
      end
    end
  end

  defp until_closed(socket, received, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      :gen_tcp.close(socket)
      flunk("the connection stayed open after #{inspect(received)}")
    end

    case :gen_tcp.recv(socket, 0, remaining) do
      {:ok, data} ->
        until_closed(socket, received <> data, deadline)

      {:error, :timeout} ->
        :gen_tcp.close(socket)
        flunk("the connection stayed open after #{inspect(received)}")

      {:error, _closed} ->
        received
    end
  end
end
