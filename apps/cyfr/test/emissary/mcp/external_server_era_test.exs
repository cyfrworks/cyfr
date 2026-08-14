# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.ExternalServerEraTest do
  @moduledoc """
  CYFR is a client as well as a server, and the ecosystem it talks to is mixed.

  The fallback exists for third-party servers on the older revision — the
  bundled `apps/mcp-bridge` speaks the current one inbound, so the default
  deployment never takes it.

  What has to hold is that the fallback triggers on the right signal. A modern
  server also answers `4xx` — for an unsupported version, a missing capability,
  a header mismatch — and treating those as "this peer is old" would downgrade a
  current server on a recoverable error and keep it downgraded, since the era is
  cached.
  """
  use ExUnit.Case, async: false

  alias Emissary.MCP.{ExternalServer, Protocol}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    bypass = Bypass.open()
    {:ok, bypass: bypass, url: "http://127.0.0.1:#{bypass.port}/mcp"}
  end

  # Connection is lazy — the first request for tools is what triggers it, so
  # that is also what exercises era negotiation.
  defp connect(url, name) do
    config = [name: name, url: url, org_id: "local", project_id: "default"]
    pid = start_supervised!({ExternalServer, config}, id: name)
    result = GenServer.call(pid, :get_tools, 5_000)
    {pid, result}
  end

  defp read_body(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    {Jason.decode!(body), conn}
  end

  defp json(conn, payload) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(payload))
  end

  describe "a modern peer" do
    test "is used directly, with no handshake at all", %{bypass: bypass, url: url} do
      methods = :counters.new(1, [])
      test_pid = self()

      Bypass.expect(bypass, "POST", "/mcp", fn conn ->
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

    test "every request carries the per-request metadata", %{bypass: bypass, url: url} do
      test_pid = self()

      Bypass.expect(bypass, "POST", "/mcp", fn conn ->
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
  end

  describe "a legacy peer" do
    test "falls back to the handshake after a bare 4xx", %{bypass: bypass, url: url} do
      test_pid = self()

      Bypass.expect(bypass, "POST", "/mcp", fn conn ->
        {body, conn} = read_body(conn)
        send(test_pid, {:method, body["method"]})

        modern? = get_in(body, ["params", "_meta"]) != nil

        case body["method"] do
          # No JSON-RPC error body: the shape a pre-2026 server produces for a
          # request it cannot parse.
          "tools/list" when modern? ->
            Plug.Conn.resp(conn, 400, "Bad Request")

          "initialize" ->
            json(conn, %{
              "jsonrpc" => "2.0",
              "id" => body["id"],
              "result" => %{"serverInfo" => %{"name" => "old", "version" => "1"}}
            })

          "notifications/initialized" ->
            Plug.Conn.resp(conn, 202, "")

          "tools/list" ->
            json(conn, %{"jsonrpc" => "2.0", "id" => body["id"], "result" => %{"tools" => []}})
        end
      end)

      {pid, {:ok, _tools}} = connect(url, "legacy-peer")

      assert %{status: :ready, server_info: %{"name" => "old"}} =
               GenServer.call(pid, :status, 5_000)

      assert_received {:method, "tools/list"}
      assert_received {:method, "initialize"}
    end
  end

  describe "a modern peer having a bad day is not mistaken for a legacy one" do
    # The era is cached, so a wrong call here downgrades a current server for the
    # life of the connection — on an error that says "retry differently".
    test "a JSON-RPC error in a 4xx body means modern, not old", %{bypass: bypass, url: url} do
      test_pid = self()

      Bypass.expect(bypass, "POST", "/mcp", fn conn ->
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
end
