# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.External.ServerEraTest do
  @moduledoc """
  CYFR is a client as well as a server, and the ecosystem it talks to is mixed.

  The fallback exists for third-party servers on the older revision — the
  bundled backends service (`Locus.Backends.Service`) speaks the current one
  inbound, so the default deployment never takes it.

  What has to hold is that the fallback triggers on the right signal. A modern
  server also answers `4xx` — for an unsupported version, a missing capability,
  a header mismatch — and treating those as "this peer is old" would downgrade a
  current server on a recoverable error and keep it downgraded, since the era is
  cached.
  """
  use ExUnit.Case, async: false

  alias Cyfr.Test.HTTPStub
  alias Emissary.External.Server
  alias Prima.MCP.Protocol

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    stub = HTTPStub.open()
    {:ok, stub: stub, url: "http://127.0.0.1:#{stub.port}/mcp"}
  end

  # Connection is lazy — the first request for tools is what triggers it, so
  # that is also what exercises era negotiation.
  defp connect(url, name) do
    config = [name: name, url: url, athanor_id: "ath_test"]
    pid = start_supervised!({Server, config}, id: name)
    result = GenServer.call(pid, :get_tools, 5_000)
    {pid, result}
  end

  defp read_body(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    {Jason.decode!(body), conn}
  end

  # Twelve whitespace chunks 75 ms apart, then the payload: each chunk lands
  # well inside a 300 ms receive timeout, the whole reply well outside it.
  defp trickle(conn, payload) do
    conn =
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_chunked(200)

    conn =
      Enum.reduce(1..12, conn, fn _, conn ->
        Process.sleep(75)

        case Plug.Conn.chunk(conn, " ") do
          {:ok, conn} -> conn
          {:error, _closed} -> conn
        end
      end)

    _ = Plug.Conn.chunk(conn, Jason.encode!(payload))
    conn
  end

  defp json(conn, payload) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(payload))
  end

  describe "a modern peer" do
    test "is used directly, with no handshake at all", %{stub: stub, url: url} do
      methods = :counters.new(1, [])
      test_pid = self()

      HTTPStub.expect(stub, "POST", "/mcp", fn conn ->
        {body, conn} = read_body(conn)
        send(test_pid, {:method, body["method"], Plug.Conn.get_req_header(conn, "mcp-method")})
        :counters.add(methods, 1, 1)

        json(conn, %{"jsonrpc" => "2.0", "id" => body["id"], "result" => %{"tools" => []}})
      end)

      {pid, {:ok, _tools}} = connect(url, "modern-peer")
      assert %{status: :ready} = GenServer.call(pid, :status, 5_000)

      # One call, and it was tools/list — no initialize, no initialized.
      assert :counters.get(methods, 1) == 1
      assert_received {:method, "tools/list", ["tools/list"]}
    end

    test "every request carries the per-request metadata", %{stub: stub, url: url} do
      test_pid = self()

      HTTPStub.expect(stub, "POST", "/mcp", fn conn ->
        {body, conn} = read_body(conn)
        send(test_pid, {:request, body, Plug.Conn.get_req_header(conn, "mcp-protocol-version")})
        json(conn, %{"jsonrpc" => "2.0", "id" => body["id"], "result" => %{"tools" => []}})
      end)

      {pid, {:ok, _tools}} = connect(url, "meta-peer")
      assert %{status: :ready} = GenServer.call(pid, :status, 5_000)

      assert_received {:request, body, [version_header]}
      meta = body["params"]["_meta"]

      assert meta[Protocol.meta_protocol_version_key()] == Protocol.version()
      assert is_map(meta[Protocol.meta_client_capabilities_key()])
      # Header and body must agree or a conforming peer refuses the request.
      assert version_header == meta[Protocol.meta_protocol_version_key()]
    end

    test "a paged listing is followed to its last page", %{stub: stub, url: url} do
      HTTPStub.expect(stub, "POST", "/mcp", fn conn ->
        {body, conn} = read_body(conn)

        result =
          case body["params"]["cursor"] do
            nil -> %{"tools" => [%{"name" => "first"}], "nextCursor" => "page-two"}
            "page-two" -> %{"tools" => [%{"name" => "second"}], "nextCursor" => "page-three"}
            "page-three" -> %{"tools" => [%{"name" => "third"}]}
          end

        json(conn, %{"jsonrpc" => "2.0", "id" => body["id"], "result" => result})
      end)

      {_pid, {:ok, tools}} = connect(url, "paging-peer")
      assert Enum.map(tools, & &1["name"]) == ["first", "second", "third"]
    end

    test "a listing that never ends fails the connect", %{stub: stub, url: url} do
      pages = :counters.new(1, [])

      HTTPStub.expect(stub, "POST", "/mcp", fn conn ->
        {body, conn} = read_body(conn)
        :counters.add(pages, 1, 1)
        page = %{"tools" => [%{"name" => "t#{body["id"]}"}], "nextCursor" => "more"}
        json(conn, %{"jsonrpc" => "2.0", "id" => body["id"], "result" => page})
      end)

      {pid, {:error, reason}} = connect(url, "endless-peer")
      assert reason =~ "listed more than 20 pages of tools"
      assert :counters.get(pages, 1) == 20
      assert %{status: :error, tool_count: 0} = GenServer.call(pid, :status, 5_000)
    end

    test "a listing trickled past its deadline fails the connect", %{stub: stub, url: url} do
      HTTPStub.stub(stub, "POST", "/mcp", fn conn ->
        {body, conn} = read_body(conn)
        trickle(conn, %{"jsonrpc" => "2.0", "id" => body["id"], "result" => %{"tools" => []}})
      end)

      config = [name: "trickled-list-peer", url: url, athanor_id: "ath_test", timeout_ms: 300]
      pid = start_supervised!({Server, config})

      assert {:error, reason} = GenServer.call(pid, :get_tools, 10_000)
      assert reason =~ "did not finish listing its tools within 300 ms"
      HTTPStub.pass(stub)
    end

    # The handshake limit is the server's timeout where that is shorter, so
    # a one-second timeout puts the whole listing under one second.
    test "a slow listing fails at the deadline, not at the page bound",
         %{stub: stub, url: url} do
      pages = :counters.new(1, [])

      HTTPStub.stub(stub, "POST", "/mcp", fn conn ->
        {body, conn} = read_body(conn)
        :counters.add(pages, 1, 1)
        Process.sleep(300)
        page = %{"tools" => [%{"name" => "t#{body["id"]}"}], "nextCursor" => "more"}
        json(conn, %{"jsonrpc" => "2.0", "id" => body["id"], "result" => page})
      end)

      config = [name: "slow-peer", url: url, athanor_id: "ath_test", timeout_ms: 1_000]
      pid = start_supervised!({Server, config})

      assert {:error, reason} = GenServer.call(pid, :get_tools, 10_000)
      assert reason =~ "did not finish listing its tools within 1000 ms"
      assert :counters.get(pages, 1) < 20
      assert %{status: :error, tool_count: 0} = GenServer.call(pid, :status, 5_000)
      HTTPStub.pass(stub)
    end
  end

  describe "a legacy peer" do
    # A stateful peer on the older revision, as the common servers are: it
    # issues a session at `initialize` and answers any later request that
    # does not carry it 400.
    # `:issue` is the session it issues, `:require` the one it then
    # requires (the issued one unless the client is configured with its
    # own) and `:answer` answers everything after the handshake.
    defp legacy_peer(stub, test_pid, opts \\ []) do
      issued = Keyword.get(opts, :issue, "peer-session")
      required = Keyword.get(opts, :require, issued)
      answer = Keyword.get(opts, :answer, &answer_listing/2)

      HTTPStub.expect(stub, "POST", "/mcp", fn conn ->
        {body, conn} = read_body(conn)
        session = Plug.Conn.get_req_header(conn, "mcp-session-id")
        send(test_pid, {:method, body["method"], session})

        modern? = get_in(body, ["params", "_meta"]) != nil

        case body["method"] do
          # No JSON-RPC error body: the shape a pre-2026 server produces for a
          # request it cannot parse.
          "tools/list" when modern? ->
            Plug.Conn.resp(conn, 400, "Bad Request")

          "initialize" ->
            conn
            |> Plug.Conn.put_resp_header("mcp-session-id", issued)
            |> json(%{
              "jsonrpc" => "2.0",
              "id" => body["id"],
              "result" => %{"serverInfo" => %{"name" => "old", "version" => "1"}}
            })

          _method when session != [required] ->
            Plug.Conn.resp(conn, 400, "Bad Request: No valid session ID provided")

          "notifications/initialized" ->
            Plug.Conn.resp(conn, 202, "")

          _method ->
            answer.(conn, body)
        end
      end)
    end

    defp refuse_echoing_session(conn, body) do
      [session] = Plug.Conn.get_req_header(conn, "mcp-session-id")

      json(conn, %{
        "jsonrpc" => "2.0",
        "id" => body["id"],
        "error" => %{"code" => -32000, "message" => "session rejected: #{session}"}
      })
    end

    defp answer_listing(conn, %{"method" => "tools/list"} = body),
      do:
        json(conn, %{
          "jsonrpc" => "2.0",
          "id" => body["id"],
          "result" => %{"tools" => [%{"name" => "echo"}]}
        })

    defp answer_listing(conn, %{"method" => "tools/call"} = body),
      do: json(conn, %{"jsonrpc" => "2.0", "id" => body["id"], "result" => %{"echo" => true}})

    test "falls back to the handshake after a bare 4xx", %{stub: stub, url: url} do
      legacy_peer(stub, self())

      {pid, {:ok, _tools}} = connect(url, "legacy-peer")

      assert %{status: :ready, server_info: %{"name" => "old"}} =
               GenServer.call(pid, :status, 5_000)

      assert_received {:method, "tools/list", []}
      assert_received {:method, "initialize", []}
    end

    test "every request after initialize carries the session it issued",
         %{stub: stub, url: url} do
      legacy_peer(stub, self())

      {pid, {:ok, [%{"name" => "echo"}]}} = connect(url, "session-peer")
      assert {:ok, %{"echo" => true}} = Server.call_tool(pid, "echo", %{})

      assert_received {:method, "initialize", []}
      assert_received {:method, "notifications/initialized", ["peer-session"]}
      assert_received {:method, "tools/list", ["peer-session"]}
      assert_received {:method, "tools/call", ["peer-session"]}
    end

    test "the session a peer echoes in a refusal stays out of the log", %{stub: stub, url: url} do
      legacy_peer(stub, self(), answer: &refuse_echoing_session/2)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {_pid, {:error, reason}} = connect(url, "session-echo-peer")
          refute reason =~ "peer-session"
        end)

      assert log =~ "Failed to initialize session-echo-peer"
      refute log =~ "peer-session"
    end

    test "the session stays out of the process's status", %{stub: stub, url: url} do
      legacy_peer(stub, self())

      {pid, {:ok, _tools}} = connect(url, "session-status-peer")
      refute inspect(:sys.get_status(pid), limit: :infinity) =~ "peer-session"
      refute inspect(:sys.get_state(pid), limit: :infinity) =~ "peer-session"
    end

    # Masking leaves out values shorter than eight bytes, so an id that
    # short could not be kept out of the log: it is not kept at all.
    test "a session id too short to mask fails the connect", %{stub: stub, url: url} do
      legacy_peer(stub, self(), issue: "Sess123", answer: &refuse_echoing_session/2)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {_pid, {:error, reason}} = connect(url, "short-session-peer")
          assert reason =~ "issued a session id too short to keep"
        end)

      refute log =~ "Sess123"
      refute_received {:method, "notifications/initialized", _session}
    end

    test "a session id that is not visible ASCII fails the connect", %{stub: stub, url: url} do
      legacy_peer(stub, self(), issue: "peer session")

      assert {_pid, {:error, reason}} = connect(url, "spaced-session-peer")
      assert reason =~ "issued a session id that is not visible ASCII"
    end

    test "a reconnect does not send the session issued before it", %{stub: stub, url: url} do
      legacy_peer(stub, self())

      {pid, {:ok, _tools}} = connect(url, "reconnecting-peer")
      assert_handshake()

      assert {:ok, :ready} = GenServer.call(pid, :reinitialize, 5_000)
      assert_handshake()
    end

    # The probe and initialize carry no session; everything after carries
    # the one initialize issued.
    defp assert_handshake do
      assert_received {:method, "tools/list", []}
      assert_received {:method, "initialize", []}
      assert_received {:method, "notifications/initialized", ["peer-session"]}
      assert_received {:method, "tools/list", ["peer-session"]}
    end

    # A trickling peer holds initialize as it could a listing: each chunk
    # restarts the wait for the next.
    test "a trickled initialize fails at the request's timeout", %{stub: stub, url: url} do
      HTTPStub.stub(stub, "POST", "/mcp", fn conn ->
        {body, conn} = read_body(conn)

        if get_in(body, ["params", "_meta"]),
          do: Plug.Conn.resp(conn, 400, "Bad Request"),
          else: trickle(conn, %{"jsonrpc" => "2.0", "id" => body["id"], "result" => %{}})
      end)

      config = [name: "trickled-init-peer", url: url, athanor_id: "ath_test", timeout_ms: 300]
      pid = start_supervised!({Server, config})

      assert {:error, _reason} = GenServer.call(pid, :get_tools, 10_000)
      assert %{status: :error} = GenServer.call(pid, :status, 5_000)
      HTTPStub.pass(stub)
    end
  end

  describe "a modern peer having a bad day is not mistaken for a legacy one" do
    # The era is cached, so a wrong call here downgrades a current server for the
    # life of the connection — on an error that says "retry differently".
    test "a JSON-RPC error in a 4xx body means modern, not old", %{stub: stub, url: url} do
      test_pid = self()

      HTTPStub.expect(stub, "POST", "/mcp", fn conn ->
        {body, conn} = read_body(conn)
        send(test_pid, {:method, body["method"]})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          400,
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => body["id"],
            "error" => %{"code" => -32022, "message" => "Unsupported protocol version"}
          })
        )
      end)

      {pid, {:error, _reason}} = connect(url, "grumpy-modern-peer")
      assert %{status: :error} = GenServer.call(pid, :status, 5_000)

      # It never tried the handshake: the body identified a current server.
      assert_received {:method, "tools/list"}
      refute_received {:method, "initialize"}
    end
  end

  describe "a reply is this request's response or it is refused" do
    # The reply is read through the codec: a peer's own request is never the
    # answer to this one, a response carrying both result and error is not
    # decidable, and an answer to another id belongs to another call. Each
    # is refused with one sentence of this node's, never the body's.
    defp answering(stub, reply) do
      HTTPStub.expect(stub, "POST", "/mcp", fn conn ->
        {body, conn} = read_body(conn)
        json(conn, reply.(body["id"]))
      end)
    end

    test "a request carrying this request's id is not its response", %{stub: stub, url: url} do
      answering(stub, fn id ->
        %{"jsonrpc" => "2.0", "id" => id, "method" => "sampling/createMessage", "params" => %{}}
      end)

      {pid, {:error, reason}} = connect(url, "asking-peer")
      assert reason =~ "not the response to this request"
      assert %{status: :error, tool_count: 0} = GenServer.call(pid, :status, 5_000)
    end

    test "a response carrying both result and error is refused", %{stub: stub, url: url} do
      answering(stub, fn id ->
        %{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => %{"tools" => [%{"name" => "t"}]},
          "error" => %{"code" => -32603, "message" => "secret-diagnostic"}
        }
      end)

      {pid, {:error, reason}} = connect(url, "both-peer")
      assert reason =~ "not the response to this request"
      refute reason =~ "secret-diagnostic"
      assert %{status: :error, tool_count: 0} = GenServer.call(pid, :status, 5_000)
    end

    test "an answer to another id is not this request's", %{stub: stub, url: url} do
      answering(stub, fn id ->
        %{"jsonrpc" => "2.0", "id" => "not-#{id}", "result" => %{"tools" => []}}
      end)

      {_pid, {:error, reason}} = connect(url, "other-id-peer")
      assert reason =~ "not the response to this request"
    end

    test "an error response with a null id is refused", %{stub: stub, url: url} do
      answering(stub, fn _id ->
        %{"jsonrpc" => "2.0", "id" => nil, "error" => %{"code" => -32603, "message" => "x"}}
      end)

      {_pid, {:error, reason}} = connect(url, "null-id-peer")
      assert reason =~ "not the response to this request"
    end
  end
end
