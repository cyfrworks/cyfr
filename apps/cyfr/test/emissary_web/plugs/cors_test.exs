# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.Plugs.CORSTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Emissary.MCP.Protocol
  alias EmissaryWeb.Plugs.CORS

  # An OPTIONS preflight against the real plug, wildcard origin.
  defp preflight_headers(header) do
    Application.put_env(:cyfr, :cors_allowed_origins, ["*"])

    conn(:options, "/mcp")
    |> put_req_header("origin", "https://example.com")
    |> CORS.call(CORS.init([]))
    |> get_resp_header(header)
    |> List.first()
    |> to_string()
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.downcase/1)
  end

  setup do
    original = Application.get_env(:cyfr, :cors_allowed_origins)
    on_exit(fn -> Application.put_env(:cyfr, :cors_allowed_origins, original) end)
    :ok
  end

  describe "OPTIONS preflight" do
    test "returns 204 with CORS headers" do
      Application.put_env(:cyfr, :cors_allowed_origins, ["*"])

      conn =
        conn(:options, "/mcp")
        |> put_req_header("origin", "https://example.com")
        |> CORS.call(CORS.init([]))

      assert conn.status == 204
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      assert get_resp_header(conn, "access-control-allow-methods") |> List.first() =~ "POST"

      assert get_resp_header(conn, "access-control-allow-headers") |> List.first() =~
               "content-type"

      assert get_resp_header(conn, "access-control-expose-headers") ==
               [Enum.join(Protocol.exposed_headers(), ", ")]

      assert conn.halted
    end

    test "returns 204 with specific origin when configured" do
      Application.put_env(:cyfr, :cors_allowed_origins, ["https://app.cyfr.run"])

      conn =
        conn(:options, "/mcp")
        |> put_req_header("origin", "https://app.cyfr.run")
        |> CORS.call(CORS.init([]))

      assert conn.status == 204
      assert get_resp_header(conn, "access-control-allow-origin") == ["https://app.cyfr.run"]
    end

    test "no allow-origin header for disallowed origin" do
      Application.put_env(:cyfr, :cors_allowed_origins, ["https://app.cyfr.run"])

      conn =
        conn(:options, "/mcp")
        |> put_req_header("origin", "https://evil.com")
        |> CORS.call(CORS.init([]))

      assert conn.status == 204
      assert get_resp_header(conn, "access-control-allow-origin") == []
    end
  end

  # The regression this guards: `Mcp-Method` / `Mcp-Name` / `MCP-Protocol-Version`
  # became mandatory, `MCPSession` began rejecting requests that omit them, and
  # the preflight was not updated — so every cross-origin client failed in the
  # browser before reaching any code that could report why. The bundled compose
  # deployment proxies the PWA same-origin, so nothing preflights there and
  # nothing caught it.
  describe "preflight advertises every header the server requires" do
    test "allow-headers is a superset of Protocol.request_headers/0" do
      advertised = preflight_headers("access-control-allow-headers")
      missing = Protocol.request_headers() -- advertised

      assert missing == [],
             """
             These headers are required by EmissaryWeb.Plugs.MCPSession but are not
             advertised in the CORS preflight, so a cross-origin client cannot send
             them and the browser refuses the request:

               #{Enum.join(missing, "\n  ")}

             Both sides read Emissary.MCP.Protocol.request_headers/0 — add it there.
             """
    end

    test "allow-headers carries the credential and content headers a client needs" do
      advertised = preflight_headers("access-control-allow-headers")

      for header <- ~w(content-type authorization accept) do
        assert header in advertised
      end
    end

    test "expose-headers matches Protocol.exposed_headers/0" do
      assert preflight_headers("access-control-expose-headers") == Protocol.exposed_headers()
    end

    test "DELETE is not advertised — no mount routes it" do
      refute "delete" in preflight_headers("access-control-allow-methods")
    end

    test "each mount advertises only the verbs it routes" do
      Application.put_env(:cyfr, :cors_allowed_origins, ["*"])

      methods = fn opts ->
        conn(:options, "/mcp")
        |> put_req_header("origin", "https://example.com")
        |> CORS.call(CORS.init(opts))
        |> get_resp_header("access-control-allow-methods")
        |> List.first()
        |> String.split(", ")
        |> Enum.sort()
      end

      assert methods.(methods: ~w(POST)) == ["OPTIONS", "POST"]
      assert methods.(methods: ~w(GET POST)) == ["GET", "OPTIONS", "POST"]
      # OPTIONS is appended, never duplicated.
      assert methods.(methods: ~w(POST OPTIONS)) == ["OPTIONS", "POST"]
    end

    # A header nothing reads must not be advertised: a preflight is a statement
    # about what the server accepts, and `mcp-session-id` has no reader left.
    test "the retired session header is not advertised" do
      refute "mcp-session-id" in preflight_headers("access-control-allow-headers")
    end

    # `last-event-id` belongs to the execution event stream, not to MCP.
    # Advertising it everywhere claimed support for something no MCP handler
    # reads; each mount now names the extra headers it actually accepts.
    test "each mount advertises only the extra headers it accepts" do
      Application.put_env(:cyfr, :cors_allowed_origins, ["*"])

      headers = fn opts ->
        conn(:options, "/mcp")
        |> put_req_header("origin", "https://example.com")
        |> CORS.call(CORS.init(opts))
        |> get_resp_header("access-control-allow-headers")
        |> List.first()
        |> String.split(", ")
      end

      refute "last-event-id" in headers.([])
      assert "last-event-id" in headers.(headers: ~w(last-event-id))

      # The common set is still there alongside the extra one.
      assert "authorization" in headers.(headers: ~w(last-event-id))
    end
  end

  describe "non-OPTIONS requests" do
    test "adds CORS headers without halting" do
      Application.put_env(:cyfr, :cors_allowed_origins, ["*"])

      conn =
        conn(:post, "/mcp")
        |> put_req_header("origin", "https://example.com")
        |> CORS.call(CORS.init([]))

      refute conn.halted
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]

      assert get_resp_header(conn, "access-control-expose-headers") ==
               [Enum.join(Protocol.exposed_headers(), ", ")]

      assert get_resp_header(conn, "vary") == ["Origin"]
    end

    test "sets Vary: Origin even without matching origin" do
      Application.put_env(:cyfr, :cors_allowed_origins, ["https://app.cyfr.run"])

      conn =
        conn(:post, "/mcp")
        |> put_req_header("origin", "https://evil.com")
        |> CORS.call(CORS.init([]))

      assert get_resp_header(conn, "vary") == ["Origin"]
      assert get_resp_header(conn, "access-control-allow-origin") == []
    end

    test "no origin header present" do
      Application.put_env(:cyfr, :cors_allowed_origins, ["*"])

      conn =
        conn(:post, "/mcp")
        |> CORS.call(CORS.init([]))

      # Wildcard still set when configured as ["*"]
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
    end
  end
end
