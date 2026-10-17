# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.EndpointParsersTest do
  @moduledoc """
  No route takes a multipart body, so the endpoint parses none: a
  multipart request is refused 415 before any byte of its body is read
  through `CyfrWeb.ApiError`, while every other body keeps its route's cap
  and the endpoint's 413. Reads are counted by a
  body source that reports each one, and a real connection that never
  sends its body is answered and closed. `/mcp`'s body is read in its
  own pipeline, after the rate limit and authentication
  (`CyfrWeb.EndpointParsersTest.MCPTest`); every body a caller no
  pipeline has authenticated sends is held to a host call's
  (`CyfrWeb.EndpointParsersTest.UnauthenticatedBodyTest`).
  """

  # Every request here is refused in the endpoint, before any route runs:
  # nothing reaches the database or changes shared state.
  use ExUnit.Case, async: true

  import Phoenix.ConnTest, only: [assert_error_sent: 2]
  import Plug.Conn

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

  @doc false
  def request(method, url, body, content_type) do
    method
    |> Plug.Test.conn(url, body)
    |> put_req_header("content-type", content_type)
    |> put_req_header("accept", "application/json")
    |> CountingBody.wrap()
  end

  defp call(conn), do: CyfrWeb.Endpoint.call(conn, CyfrWeb.Endpoint.init([]))

  @doc false
  def bytes_read(total \\ 0) do
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

  # A route's path with each parameter and glob filled in.
  @doc false
  def concrete(path) do
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

      for path <- paths, not mcp?(path), method <- [:post, :put, :patch, :delete] do
        assert_api_refusal(request(method, concrete(path), "--r8--", @multipart))
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
      for path <- ["/hooks/wh_any", "/directory/v1/genesis", "/restore"] do
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
        assert response =~ ~s("message":"This endpoint takes no multipart bodies")
      end
    end
  end

  @doc false
  def until_closed(socket, received, deadline) do
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

defmodule CyfrWeb.EndpointParsersTest.MCPTest do
  @moduledoc """
  `/mcp`'s body is read only in its own pipeline, after the transport's
  rate limit and authentication: a throttled request, an invalid
  credential and a refused media type answer before any byte of the body
  is read, and a caller not authenticated is held to a host call's body
  (`Prima.HostAPI.max_body_bytes/0`), a larger declared length refused
  unread and a body of unknown length read only up to it. Each answer
  sent with the body unread ends its HTTP/1 connection. An authenticated
  caller's body keeps the endpoint's length. Reads are counted through
  the endpoint by `CyfrWeb.EndpointParsersTest.CountingBody`, and a real
  connection that never sends its body is answered from its headers.
  """

  # Through the router: the rate limit reads its settings, a refusal is
  # recorded and the test person authenticates, so the module runs alone.
  use Emissary.Web.ConnCase, async: false

  import CyfrWeb.EndpointParsersTest, only: [request: 4, bytes_read: 0, until_closed: 3]

  alias Cyfr.Test.Settings
  alias Prima.MCP.{Message, Protocol}

  # The defect's size: under the endpoint's own 28 MB, so only the order
  # of the read and the checks decides what it costs.
  @flood_bytes 27_000_000

  setup_all do
    {:ok, flood: json_body("tools/list", %{"pad" => :binary.copy(<<?x>>, @flood_bytes)})}
  end

  setup do
    Prima.Test.RateLimiter.reset!()
    on_exit(&Prima.Test.RateLimiter.reset!/0)
    :ok
  end

  # A conforming JSON-RPC request, encoded as a client sends it.
  defp json_body(method, params) do
    meta = %{
      Protocol.meta_protocol_version_key() => Protocol.version(),
      Protocol.meta_client_info_key() => %{"name" => "test", "version" => "0.0.0"},
      Protocol.meta_client_capabilities_key() => %{}
    }

    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => 2,
      "method" => method,
      "params" => Map.put(params, "_meta", meta)
    })
  end

  defp mcp(body, opts \\ []) do
    conn =
      request(:post, Keyword.get(opts, :url, "/mcp"), body, "application/json")
      |> put_req_header("mcp-protocol-version", Protocol.version())

    conn =
      if Keyword.get(opts, :declared, true),
        do: put_req_header(conn, "content-length", Integer.to_string(byte_size(body))),
        else: conn

    Enum.reduce(Keyword.get(opts, :headers, []), conn, fn {name, value}, conn ->
      put_req_header(conn, name, value)
    end)
  end

  defp call(conn), do: CyfrWeb.Endpoint.call(conn, CyfrWeb.Endpoint.init([]))

  defp assert_unread_refusal(conn, status) do
    assert conn.halted
    assert conn.status == status, "answered #{conn.status}: #{conn.resp_body}"
    body = Jason.decode!(conn.resp_body)
    assert body["jsonrpc"] == "2.0"
    assert body["id"] == nil
    assert get_resp_header(conn, "mcp-protocol-version") != []
    assert get_resp_header(conn, "connection") == ["close"]
    assert bytes_read() == 0, "the refused body was read"
    body
  end

  describe "a caller not authenticated" do
    test "is refused a 27 MB body 413 before any byte of it is read, however the path is spelled",
         %{flood: flood} do
      for url <- ["/mcp", "http://www.example.com//mcp"] do
        body = flood |> mcp(url: url) |> call() |> assert_unread_refusal(413)
        assert body["error"]["code"] == Message.error_code(:invalid_request)
      end
    end

    test "of unknown length is read only up to a host call's body, then refused 413",
         %{flood: flood} do
      conn = flood |> mcp(declared: false) |> call()

      assert conn.status == 413
      assert Jason.decode!(conn.resp_body)["id"] == nil
      assert get_resp_header(conn, "connection") == ["close"]
      assert bytes_read() == Prima.HostAPI.max_body_bytes()
    end

    test "is answered within a host call's body, the body read whole" do
      body = json_body("tools/list", %{})
      conn = body |> mcp() |> put_req_header("mcp-method", "tools/list") |> call()

      assert %{"id" => 2, "result" => %{"tools" => [_ | _]}} = Jason.decode!(conn.resp_body)
      assert conn.status == 200
      assert get_resp_header(conn, "connection") == []
      assert bytes_read() == byte_size(body)
    end

    test "cannot move a body to another verb with _method" do
      body =
        Jason.encode!(%{
          "_method" => "DELETE",
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "tools/list",
          "params" => Jason.decode!(json_body("tools/list", %{}))["params"]
        })

      conn = body |> mcp() |> put_req_header("mcp-method", "tools/list") |> call()

      assert conn.method == "POST"
      assert %{"id" => 2, "result" => %{"tools" => [_ | _]}} = Jason.decode!(conn.resp_body)
    end
  end

  describe "a refusal before the body" do
    test "of a throttled request reads none of it", %{flood: flood} do
      Settings.put("mcp_rate_limit_max", 1)

      assert json_body("tools/list", %{})
             |> mcp()
             |> put_req_header("mcp-method", "tools/list")
             |> call()
             |> Map.fetch!(:status) == 200

      _ = bytes_read()

      conn = flood |> mcp() |> call()
      body = assert_unread_refusal(conn, 429)
      assert body["error"]["code"] == Message.error_code(:rate_limited)
      assert get_resp_header(conn, "retry-after") != []
    end

    test "of an invalid credential reads none of it", %{flood: flood} do
      conn = flood |> mcp(headers: [{"authorization", "Bearer cyfr_not_a_key"}]) |> call()
      assert_unread_refusal(conn, 401)
    end

    test "of a bearer nothing claims reads none of it", %{flood: flood} do
      conn = flood |> mcp(headers: [{"authorization", "Bearer not-a-session"}]) |> call()
      assert_unread_refusal(conn, 401)
    end

    test "of a multipart body is 415 in JSON-RPC, -32700 with a null id, unread" do
      for url <- ["/mcp", "http://www.example.com//mcp"], method <- [:post, :delete] do
        conn = request(method, url, "--r8--", "multipart/mixed; boundary=r8") |> call()
        body = assert_unread_refusal(conn, 415)
        assert body["error"]["code"] == Message.error_code(:parse_error)
      end
    end
  end

  describe "an authenticated caller" do
    @tag auth: :person
    test "keeps the endpoint's length: a body past a host call's is read whole and reaches the gate",
         %{conn: authenticated} do
      [bearer] = get_req_header(authenticated, "authorization")
      extra = :binary.copy(<<?x>>, 2 * Prima.HostAPI.max_body_bytes())

      body =
        json_body("tools/call", %{
          "name" => "system",
          "arguments" => %{"action" => "status", "extra" => extra}
        })

      conn =
        body
        |> mcp(
          headers: [
            {"authorization", bearer},
            {"mcp-method", "tools/call"},
            {"mcp-name", "system"}
          ]
        )
        |> call()

      # Decoded, so the typed gate refuses the undeclared argument by name.
      assert %{"id" => 2, "error" => %{"message" => "Unknown field: extra"}} =
               Jason.decode!(conn.resp_body)

      assert conn.status == 400
      assert get_resp_header(conn, "connection") == []
      assert bytes_read() == byte_size(body)
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

    test "an anonymous 27 MB request and a multipart one are answered from their headers alone, " <>
           "and their connections end without their bodies",
         %{port: port} do
      for {type, status} <- [
            {"application/json", 413},
            {"multipart/form-data; boundary=r8", 415}
          ] do
        {:ok, socket} =
          :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :raw], 5_000)

        :ok =
          :gen_tcp.send(socket, [
            "POST /mcp HTTP/1.1\r\n",
            "host: localhost\r\n",
            "accept: application/json\r\n",
            "mcp-protocol-version: #{Protocol.version()}\r\n",
            "content-type: #{type}\r\n",
            "content-length: #{@flood_bytes}\r\n\r\n"
          ])

        deadline = System.monotonic_time(:millisecond) + @answered_within
        response = until_closed(socket, "", deadline)

        assert response =~ ~r{\AHTTP/1\.1 #{status} }, "#{type} answered #{inspect(response)}"
        assert response =~ ~r{\r\nconnection: close\r\n}i
        assert response =~ ~s("jsonrpc":"2.0")
      end
    end
  end
end

defmodule CyfrWeb.EndpointParsersTest.MCPTransportTest do
  @moduledoc """
  `/mcp`'s bounds at their edges and over a real HTTP/1 connection: an
  authenticated caller's body of exactly the endpoint's 28,000,000 bytes
  is read whole and answered, one declared a byte longer is refused
  unread; a chunked anonymous body stops at a host call's body and its
  connection closes without the withheld remainder being awaited; and an
  authenticated connection stays reusable after a large chunked call and
  after an SSE answer.
  """

  use Emissary.Web.ConnCase, async: false

  import CyfrWeb.EndpointParsersTest, only: [request: 4, bytes_read: 0, until_closed: 3]

  alias Prima.MCP.Protocol

  setup do
    on_exit(&Prima.Test.RateLimiter.reset!/0)
    Prima.Test.RateLimiter.reset!()
    :ok
  end

  defp body(method \\ "tools/list", params \\ %{}) do
    meta = %{
      Protocol.meta_protocol_version_key() => Protocol.version(),
      Protocol.meta_client_info_key() => %{"name" => "test", "version" => "0.0.0"},
      Protocol.meta_client_capabilities_key() => %{}
    }

    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => 812,
      "method" => method,
      "params" => Map.put(params, "_meta", meta)
    })
  end

  defp padded_body(size) do
    json = body()
    :binary.copy(" ", size - byte_size(json)) <> json
  end

  @tag auth: :person
  test "the authenticated boundary accepts exactly 28 million bytes", %{conn: authenticated} do
    [bearer] = get_req_header(authenticated, "authorization")
    payload = padded_body(28_000_000)

    conn =
      request(:post, "/mcp", payload, "application/json")
      |> put_req_header("authorization", bearer)
      |> put_req_header("mcp-protocol-version", Protocol.version())
      |> put_req_header("mcp-method", "tools/list")
      |> put_req_header("content-length", Integer.to_string(byte_size(payload)))
      |> CyfrWeb.Endpoint.call(CyfrWeb.Endpoint.init([]))

    assert conn.status == 200
    assert %{"id" => 812, "result" => %{"tools" => [_ | _]}} = Jason.decode!(conn.resp_body)
    assert get_resp_header(conn, "connection") == []
    assert bytes_read() == 28_000_000
  end

  @tag auth: :person
  test "an authenticated declared length above 28 million bytes is refused unread", %{
    conn: authenticated
  } do
    [bearer] = get_req_header(authenticated, "authorization")

    conn =
      request(:post, "/mcp", body(), "application/json")
      |> put_req_header("authorization", bearer)
      |> put_req_header("mcp-protocol-version", Protocol.version())
      |> put_req_header("mcp-method", "tools/list")
      |> put_req_header("content-length", "28000001")
      |> CyfrWeb.Endpoint.call(CyfrWeb.Endpoint.init([]))

    assert conn.status == 413
    assert Jason.decode!(conn.resp_body)["id"] == nil
    assert get_resp_header(conn, "connection") == ["close"]
    assert bytes_read() == 0
  end

  describe "real HTTP/1 transport" do
    setup do
      {:ok, server} =
        start_supervised(
          {Bandit,
           plug: CyfrWeb.Endpoint, scheme: :http, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
      {:ok, port: port}
    end

    test "a chunked anonymous body stops at its cap without awaiting the withheld remainder", %{
      port: port
    } do
      socket = connect(port)
      cap = Prima.HostAPI.max_body_bytes()

      :ok =
        :gen_tcp.send(socket, [
          headers("transfer-encoding: chunked\r\n"),
          Integer.to_string(cap + 4096, 16),
          "\r\n",
          :binary.copy(" ", cap)
        ])

      response =
        until_closed(
          socket,
          "",
          System.monotonic_time(:millisecond) + 5_000
        )

      assert response =~ ~r/\AHTTP\/1\.1 413 /
      assert response =~ ~r/\r\nconnection: close\r\n/i
      assert response =~ ~s("id":null)
      assert response =~ ~s("code":-32600)
    end

    @tag auth: :person
    test "an authenticated large chunked call keeps its connection for the next call", %{
      port: port,
      conn: authenticated
    } do
      [bearer] = get_req_header(authenticated, "authorization")
      socket = connect(port)
      payload = padded_body(2 * Prima.HostAPI.max_body_bytes())

      :ok =
        :gen_tcp.send(socket, [
          headers("authorization: #{bearer}\r\ntransfer-encoding: chunked\r\n"),
          Integer.to_string(byte_size(payload), 16),
          "\r\n",
          payload,
          "\r\n0\r\n\r\n"
        ])

      {status, response_headers, response, rest} = receive_response(socket)
      assert status == 200
      refute response_headers["connection"] == "close"
      assert %{"id" => 812, "result" => %{"tools" => [_ | _]}} = Jason.decode!(response)
      assert rest == ""

      send_json(socket, body(), bearer)
      {200, response_headers, response, ""} = receive_response(socket)
      refute response_headers["connection"] == "close"
      assert Jason.decode!(response)["id"] == 812
    end

    @tag auth: :person
    test "an authenticated SSE answer finishes and permits a further request on its connection",
         %{
           port: port,
           conn: authenticated
         } do
      Cyfr.Test.Settings.put("mcp_subscription_max_ms", 150)
      [bearer] = get_req_header(authenticated, "authorization")
      socket = connect(port)
      payload = body("subscriptions/listen", %{"notifications" => %{"toolsListChanged" => true}})
      send_json(socket, payload, bearer, "subscriptions/listen")

      {200, response_headers, response, ""} = receive_response(socket)
      assert response_headers["content-type"] =~ "text/event-stream"
      refute response_headers["connection"] == "close"
      assert response =~ "notifications/subscriptions/acknowledged"
      assert response =~ ~s("id":812)
      assert response =~ ~s("resultType":"complete")

      send_json(socket, body(), bearer)
      {200, response_headers, response, ""} = receive_response(socket)
      refute response_headers["connection"] == "close"
      assert Jason.decode!(response)["id"] == 812
    end
  end

  defp connect(port) do
    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :raw], 5_000)

    on_exit(fn -> :gen_tcp.close(socket) end)
    socket
  end

  defp headers(extra, method \\ "tools/list") do
    [
      "POST /mcp HTTP/1.1\r\nhost: localhost\r\naccept: application/json, text/event-stream\r\n",
      "content-type: application/json\r\nmcp-protocol-version: #{Protocol.version()}\r\n",
      "mcp-method: #{method}\r\n",
      extra,
      "\r\n"
    ]
  end

  defp send_json(socket, payload, bearer, method \\ "tools/list") do
    :ok =
      :gen_tcp.send(socket, [
        headers(
          "authorization: #{bearer}\r\ncontent-length: #{byte_size(payload)}\r\n",
          method
        ),
        payload
      ])
  end

  defp receive_response(socket) do
    {head, rest} = receive_until(socket, "", "\r\n\r\n")
    [status_line | fields] = String.split(head, "\r\n")
    ["HTTP/1.1", status | _] = String.split(status_line, " ")

    response_headers =
      Map.new(fields, fn field ->
        [name, value] = String.split(field, ":", parts: 2)
        {String.downcase(name), String.trim(value)}
      end)

    {response, rest} =
      if response_headers["transfer-encoding"] == "chunked" do
        receive_chunks(socket, rest, [])
      else
        receive_bytes(socket, rest, String.to_integer(response_headers["content-length"]))
      end

    {String.to_integer(status), response_headers, response, rest}
  end

  defp receive_until(socket, received, separator) do
    case :binary.split(received, separator) do
      [head, rest] ->
        {head, rest}

      [_] ->
        assert {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
        receive_until(socket, received <> data, separator)
    end
  end

  defp receive_bytes(socket, received, size) when byte_size(received) < size do
    assert {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
    receive_bytes(socket, received <> data, size)
  end

  defp receive_bytes(_socket, received, size) do
    <<body::binary-size(^size), rest::binary>> = received
    {body, rest}
  end

  defp receive_chunks(socket, received, chunks) do
    {size_line, rest} = receive_until(socket, received, "\r\n")
    size = String.to_integer(size_line, 16)

    if size == 0 do
      {"", rest} = receive_bytes(socket, rest, 0)
      {"\r\n", rest} = receive_bytes(socket, rest, 2)
      {chunks |> Enum.reverse() |> IO.iodata_to_binary(), rest}
    else
      {chunk, rest} = receive_bytes(socket, rest, size)
      {"\r\n", rest} = receive_bytes(socket, rest, 2)
      receive_chunks(socket, rest, [chunk | chunks])
    end
  end
end

defmodule CyfrWeb.EndpointParsersTest.UnauthenticatedBodyTest do
  @moduledoc """
  No route reads more than a host call's body
  (`Prima.HostAPI.max_body_bytes/0`) from a caller its pipeline has not
  authenticated: the endpoint parses before any route's rate limit or
  credential check, so a declared length over the cap is refused 413
  before any byte is read, a body of unknown length is cut at the cap,
  and a valid credential does not lift it where the pipeline authenticates
  after the read. The routes are the routers' own (`__routes__/0`), each
  body route naming its cap (`CyfrWeb.Plugs.RawBodyReader.cap/1`). An
  answer sent with the body unread ends its HTTP/1 connection, a refusal
  and an answer that left a body unparsed alike; a body read whole keeps
  it. The attachment allowance after `/mcp`'s rate limit and
  authentication is `CyfrWeb.EndpointParsersTest.MCPTransportTest`'s.
  """

  # Through the router: the throttles read their settings, a refusal is
  # recorded and the test person authenticates, so the module runs alone.
  use Emissary.Web.ConnCase, async: false

  import CyfrWeb.EndpointParsersTest,
    only: [request: 4, bytes_read: 0, until_closed: 3, concrete: 1]

  alias CyfrWeb.Plugs.RawBodyReader

  # Under the 28 MB attachment allowance, far over a host call's body.
  @flood_bytes 27_000_000

  # The verbs whose body the parsers read.
  @body_verbs [:post, :put, :patch, :delete]

  # The routes the defect named, each with a body no pipeline
  # authenticated before reading, and `/mcp` beside them.
  @named [
    {:post, "/_f/v1/invoke"},
    {:post, "/_f/v1/action"},
    {:post, "/_f/v1/stream"},
    {:post, "/_f/v1/o/x/stream"},
    {:delete, "/auth/logout"},
    {:post, "/no-route-matches-this"},
    {:post, "/mcp"}
  ]

  setup_all do
    {:ok, flood: ~s({"pad":") <> :binary.copy(<<?x>>, @flood_bytes) <> ~s("})}
  end

  setup do
    Prima.Test.RateLimiter.reset!()
    on_exit(&Prima.Test.RateLimiter.reset!/0)
    :ok
  end

  defp declared(conn, bytes),
    do: put_req_header(conn, "content-length", Integer.to_string(bytes))

  # The answer the endpoint sent, whether a route returned it or Phoenix
  # rendered a refusal raised while parsing.
  defp answer(conn) do
    try do
      CyfrWeb.Endpoint.call(conn, CyfrWeb.Endpoint.init([]))
    rescue
      _refusal -> :rendered
    end

    receive do
      {ref, {status, headers, _body}} when is_reference(ref) -> {status, headers}
    after
      0 -> flunk("no answer was sent")
    end
  end

  # Every route the routers declare with a verb whose body is parsed.
  defp body_routes do
    for %{verb: verb, path: path} <- CyfrWeb.Router.__routes__(),
        verb in @body_verbs,
        uniq: true,
        do: {verb, path}
  end

  describe "a caller no pipeline has authenticated" do
    test "is refused a 27 MB body 413 before any byte of it is read, on the frame data " <>
           "routes, the API's sign-out, a path no route matches and /mcp",
         %{flood: flood} do
      for {method, url} <- @named do
        {status, headers} =
          method
          |> request(url, flood, "application/json")
          |> declared(byte_size(flood))
          |> answer()

        assert status == 413, "#{method} #{url} answered #{status}"
        assert bytes_read() == 0, "#{method} #{url} read the refused body"
        assert {"connection", "close"} in headers
      end
    end

    test "of unknown length is read only up to a host call's body, then refused 413",
         %{flood: flood} do
      for {method, url} <- @named do
        {status, headers} = method |> request(url, flood, "application/json") |> answer()

        assert status == 413, "#{method} #{url} answered #{status}"
        assert bytes_read() == Prima.HostAPI.max_body_bytes(), "#{method} #{url}"
        assert {"connection", "close"} in headers
      end
    end

    @tag auth: :person
    test "holding a valid credential, is held to a host call's body where the pipeline " <>
           "authenticates after the read",
         %{conn: authenticated, flood: flood} do
      [bearer] = get_req_header(authenticated, "authorization")

      {status, _headers} =
        :delete
        |> request("/auth/logout", flood, "application/json")
        |> put_req_header("authorization", bearer)
        |> answer()

      assert status == 413
      assert bytes_read() == Prima.HostAPI.max_body_bytes()
    end

    test "is answered within a host call's body, read whole, on a connection kept open" do
      body = ~s({"pad":") <> :binary.copy(<<?x>>, 64) <> ~s("})

      {status, headers} =
        :delete
        |> request("/auth/logout", body, "application/json")
        |> declared(byte_size(body))
        |> answer()

      assert status == 401
      assert bytes_read() == byte_size(body)
      refute List.keymember?(headers, "connection", 0)
    end
  end

  describe "the inventory" do
    test "every route that takes a body names its cap, a host call's body at most, and " <>
           "refuses a longer declared body unread" do
      routes = body_routes()
      paths = Enum.map(routes, &elem(&1, 1))

      # The sweep covers the routes the failure cases name and every capped family.
      for path <- [
            "/_f/v1/invoke",
            "/_f/v1/action",
            "/_f/v1/stream",
            "/_f/v1/o/:frame_id/stream",
            "/auth/logout",
            "/mcp",
            "/hooks/:slug",
            "/directory/v1/genesis",
            "/certify/v1/renew",
            "/restore"
          ] do
        assert path in paths, "#{path} takes no body"
      end

      for {verb, path} <- routes do
        conn = request(verb, concrete(path), "{}", "application/json")
        cap = RawBodyReader.cap(conn)

        assert cap <= Prima.HostAPI.max_body_bytes(),
               "#{verb} #{path} reads #{cap} bytes from a caller not authenticated"

        {status, headers} = conn |> declared(cap + 1) |> answer()

        assert status == 413, "#{verb} #{path} answered #{status} past its cap of #{cap}"
        assert bytes_read() == 0, "#{verb} #{path} read a body declared past its cap"
        assert {"connection", "close"} in headers
      end
    end

    test "the tincture guide states a frame request's bound as the cap" do
      guide = File.read!(Path.expand("../../../../tincture-guide.md", __DIR__))

      assert Prima.HostAPI.max_body_bytes() == 1_048_576

      assert guide =~
               "| Request body | a host call's body (1 MiB) per invoke, action or stream open | " <>
                 "refused 413 before any of it is read"
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

    defp connect(port) do
      {:ok, socket} =
        :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :raw], 5_000)

      on_exit(fn -> :gen_tcp.close(socket) end)
      socket
    end

    defp head(method, path, type, framing) do
      [
        "#{method} #{path} HTTP/1.1\r\nhost: localhost\r\naccept: application/json\r\n",
        "content-type: #{type}\r\n",
        framing,
        "\r\n"
      ]
    end

    defp closed(socket),
      do: until_closed(socket, "", System.monotonic_time(:millisecond) + @answered_within)

    test "a declared 27 MB body is answered 413 from its headers alone, and its connection " <>
           "ends without it",
         %{port: port} do
      for {method, path} <- [
            {"POST", "/_f/v1/invoke"},
            {"DELETE", "/auth/logout"},
            {"POST", "/no-route-matches-this"}
          ] do
        socket = connect(port)

        :ok =
          :gen_tcp.send(
            socket,
            head(method, path, "application/json", "content-length: #{@flood_bytes}\r\n")
          )

        response = closed(socket)
        assert response =~ ~r{\AHTTP/1\.1 413 }, "#{path} answered #{inspect(response)}"
        assert response =~ ~r{\r\nconnection: close\r\n}i
      end
    end

    test "a chunked body stops at its cap without awaiting the withheld remainder", %{
      port: port
    } do
      cap = Prima.HostAPI.max_body_bytes()

      for {method, path} <- [{"POST", "/_f/v1/invoke"}, {"DELETE", "/auth/logout"}] do
        socket = connect(port)

        :ok =
          :gen_tcp.send(socket, [
            head(method, path, "application/json", "transfer-encoding: chunked\r\n"),
            Integer.to_string(cap + 4096, 16),
            "\r\n",
            :binary.copy(" ", cap)
          ])

        response = closed(socket)
        assert response =~ ~r{\AHTTP/1\.1 413 }, "#{path} answered #{inspect(response)}"
        assert response =~ ~r{\r\nconnection: close\r\n}i
      end
    end

    test "an answer that leaves a body unparsed ends its connection without awaiting it", %{
      port: port
    } do
      socket = connect(port)

      :ok =
        :gen_tcp.send(
          socket,
          head("DELETE", "/auth/logout", "text/plain", "content-length: #{@flood_bytes}\r\n")
        )

      response = closed(socket)
      assert response =~ ~r{\AHTTP/1\.1 401 }, "answered #{inspect(response)}"
      assert response =~ ~r{\r\nconnection: close\r\n}i
    end

    test "a body read whole keeps its connection for the next request", %{port: port} do
      socket = connect(port)
      body = "{}"

      for _request <- 1..2 do
        :ok =
          :gen_tcp.send(socket, [
            head("DELETE", "/auth/logout", "application/json", "content-length: 2\r\n"),
            body
          ])

        response = whole_response(socket, "")
        assert response =~ ~r{\AHTTP/1\.1 401 }, "answered #{inspect(response)}"
        refute response =~ ~r{\r\nconnection: close\r\n}i
      end
    end

    # One whole response of declared length.
    defp whole_response(socket, received) do
      with [head, rest] <- :binary.split(received, "\r\n\r\n"),
           [_, length] <- Regex.run(~r{\r\ncontent-length: (\d+)\r\n}i, head <> "\r\n"),
           true <- byte_size(rest) >= String.to_integer(length) do
        received
      else
        _incomplete ->
          assert {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
          whole_response(socket, received <> data)
      end
    end
  end
end
