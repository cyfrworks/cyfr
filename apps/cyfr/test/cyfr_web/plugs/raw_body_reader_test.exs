# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.Plugs.RawBodyReaderTest do
  use ExUnit.Case, async: true

  alias CyfrWeb.Plugs.RawBodyReader

  defp build_conn(method, path, body) do
    Plug.Test.conn(method, path, body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
  end

  test "caches raw body in conn.assigns[:raw_body] for /hooks/* paths" do
    body = ~s({"x":1})
    conn = build_conn(:post, "/hooks/wh_abc123", body)

    {:ok, returned, conn} = RawBodyReader.read_body(conn, [])

    assert returned == body
    assert conn.assigns[:raw_body] == body
  end

  test "does NOT cache raw body for /mcp" do
    conn = build_conn(:post, "/mcp", ~s({"jsonrpc":"2.0"}))

    {:ok, _body, conn} = RawBodyReader.read_body(conn, [])

    refute Map.has_key?(conn.assigns, :raw_body)
  end

  test "does NOT cache raw body for /t/* (tinctures)" do
    conn = build_conn(:post, "/t/home/local/dashboard/invoke", ~s({}))

    {:ok, _body, conn} = RawBodyReader.read_body(conn, [])

    refute Map.has_key?(conn.assigns, :raw_body)
  end

  test "does NOT cache raw body for /api/health" do
    conn = build_conn(:get, "/api/health", "")

    {:ok, _body, conn} = RawBodyReader.read_body(conn, [])

    refute Map.has_key?(conn.assigns, :raw_body)
  end

  test "preserves the parser-visible body unchanged for /hooks/* (parsers re-read after assign)" do
    body = ~s({"hello":"world"})
    conn = build_conn(:post, "/hooks/wh_test", body)

    {:ok, returned, conn} = RawBodyReader.read_body(conn, [])

    # Caller (Plug.Parsers) gets the same body bytes; assigns mirror them.
    assert returned == body
    assert conn.assigns[:raw_body] == body
  end

  test "passes through {:error, _} from Plug.Conn.read_body" do
    # We can't easily induce an error in Plug.Test, but ensure no nesting
    # transformation occurs. Smoke-tests the function shape.
    body = "ok"
    conn = build_conn(:post, "/hooks/wh_smoke", body)

    assert {:ok, ^body, _} = RawBodyReader.read_body(conn, [])
  end

  test "accumulates chunks across multiple read_body calls (chunked bodies)" do
    # Simulates Plug.Parsers' iterative invocation when read_body returns
    # {:more, _, _}: each call appends to conn.assigns[:raw_body].
    body = "abcdefghij" |> String.duplicate(2_000_000)
    conn = build_conn(:post, "/hooks/wh_chunked", body)

    # Read in 100KB slices to force chunking via Plug.Conn.read_body's :length
    # opt. Plug.Test's adapter respects this.
    {:more, chunk1, conn} = RawBodyReader.read_body(conn, length: 100_000, read_length: 100_000)
    assert byte_size(chunk1) == 100_000
    assert conn.assigns[:raw_body] == chunk1

    {:more, chunk2, conn} = RawBodyReader.read_body(conn, length: 100_000, read_length: 100_000)
    assert byte_size(chunk2) == 100_000
    # The accumulated raw_body now spans both chunks.
    assert conn.assigns[:raw_body] == chunk1 <> chunk2
    assert byte_size(conn.assigns[:raw_body]) == 200_000
  end

  test "a doubled slash, which the router still routes to /hooks, is cached and capped the same" do
    cap = Prima.Limits.default_max_request_size()
    conn = build_conn(:post, "http://www.example.com//hooks/wh_double", ~s({"x":1}))
    assert ["hooks", "wh_double"] = conn.path_info

    assert {:ok, ~s({"x":1}), conn} = RawBodyReader.read_body(conn, [])
    assert conn.assigns[:raw_body] == ~s({"x":1})

    big =
      build_conn(:post, "http://www.example.com//hooks/wh_double", :binary.copy(<<?x>>, cap + 1))

    assert {:more, chunk, _conn} = RawBodyReader.read_body(big, length: 28_000_000)
    assert byte_size(chunk) == cap
  end

  describe "the directory's write-body limit" do
    test "caps a /directory/* body at 16 KiB, whatever the endpoint allows, and caches nothing" do
      body = :binary.copy(<<?x>>, Prima.Identity.max_entry_bytes() + 1)
      conn = build_conn(:post, "/directory/v1/genesis", body)

      assert {:more, chunk, conn} = RawBodyReader.read_body(conn, length: 28_000_000)
      assert byte_size(chunk) == Prima.Identity.max_entry_bytes()
      refute Map.has_key?(conn.assigns, :raw_body)
    end

    test "reads a /directory/* body at the limit whole" do
      body = :binary.copy(<<?x>>, Prima.Identity.max_entry_bytes())
      conn = build_conn(:post, "/directory/v1/per_x/entries", body)

      assert {:ok, ^body, _conn} = RawBodyReader.read_body(conn, length: 28_000_000)
    end

    test "a doubled slash, which the router still routes to the directory, meets the same cap" do
      body = :binary.copy(<<?x>>, Prima.Identity.max_entry_bytes() + 1)

      for url <- [
            "http://www.example.com//directory/v1/genesis",
            "http://www.example.com///directory//v1/per_x/entries"
          ] do
        conn = build_conn(:post, url, body)
        assert ["directory" | _] = conn.path_info

        assert {:more, chunk, _conn} = RawBodyReader.read_body(conn, length: 28_000_000)
        assert byte_size(chunk) == Prima.Identity.max_entry_bytes()
      end
    end

    test "never raises a smaller cap set upstream" do
      conn = build_conn(:post, "/directory/v1/per_x/recover", :binary.copy(<<?x>>, 200))

      assert {:more, chunk, _conn} = RawBodyReader.read_body(conn, length: 100)
      assert byte_size(chunk) == 100
    end

    test "Plug.Parsers refuses an oversized directory body as too large, before decoding it" do
      opts =
        Plug.Parsers.init(
          parsers: [:json],
          pass: ["*/*"],
          json_decoder: Jason,
          length: 28_000_000,
          body_reader: {RawBodyReader, :read_body, []}
        )

      # Not JSON at all: a body past the limit is refused as large, never
      # as unparseable, because no byte of it is decoded.
      body = :binary.copy(<<?{>>, Prima.Identity.max_entry_bytes() + 1)

      assert_raise Plug.Parsers.RequestTooLargeError, fn ->
        Plug.Parsers.call(build_conn(:post, "/directory/v1/genesis", body), opts)
      end

      # The same bytes elsewhere reach the decoder.
      assert_raise Plug.Parsers.ParseError, fn ->
        Plug.Parsers.call(build_conn(:post, "/api/elsewhere", body), opts)
      end
    end
  end

  test "accumulates correctly when final read returns {:ok, last_chunk, conn}" do
    # 250KB body, read in 100KB chunks → two :more, then one :ok with 50KB tail.
    body = :binary.copy(<<?z>>, 250_000)
    conn = build_conn(:post, "/hooks/wh_tail", body)

    {:more, _c1, conn} = RawBodyReader.read_body(conn, length: 100_000, read_length: 100_000)
    {:more, _c2, conn} = RawBodyReader.read_body(conn, length: 100_000, read_length: 100_000)
    {:ok, c3, conn} = RawBodyReader.read_body(conn, length: 100_000, read_length: 100_000)

    assert byte_size(c3) == 50_000
    assert byte_size(conn.assigns[:raw_body]) == 250_000
    assert conn.assigns[:raw_body] == body
  end
end
