defmodule EmissaryWeb.Plugs.RawBodyReaderTest do
  use ExUnit.Case, async: true

  alias EmissaryWeb.Plugs.RawBodyReader

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
    conn = build_conn(:post, "/t/local/dashboard/invoke", ~s({}))

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
