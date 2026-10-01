# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.Plugs.ParserErrorsTest do
  @moduledoc """
  `Plug.Parsers` with media types refused before their body is read, one
  path prefix's failures answered through the renderer the caller names,
  and Phoenix's behaviour for every other parser failure. The endpoint's own wiring is
  exercised end to end in `CyfrWeb.EndpointParsersTest` and
  `Emissary.Web.MCPErrorTest`.
  """
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias CyfrWeb.Plugs.ParserErrors

  defmodule Renderer do
    @moduledoc false
    import Plug.Conn

    def halt(conn, status, code, message) do
      conn
      |> put_private(:refusal, {status, code, message})
      |> send_resp(status, "refused")
      |> Plug.Conn.halt()
    end
  end

  defmodule Plain do
    @moduledoc false
    import Plug.Conn

    def halt(conn, status, code, message) do
      conn
      |> put_private(:plain_refusal, {status, code, message})
      |> send_resp(status, "refused")
      |> Plug.Conn.halt()
    end
  end

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

  @parsers [parsers: [:json], pass: ["*/*"], json_decoder: Phoenix.json_library(), length: 64]

  @refused_message "The request body's media type is not accepted"

  defp post_to(path, body, content_type) do
    conn = conn(:post, path, body)
    if content_type, do: put_req_header(conn, "content-type", content_type), else: conn
  end

  defp counted(method, path, content_type) do
    method
    |> conn(path, ~s(--r8\r\ncontent-disposition: form-data; name="a"\r\n\r\nb\r\n--r8--))
    |> put_req_header("content-type", content_type)
    |> CountingBody.wrap()
  end

  describe "with a JSON-RPC prefix" do
    setup do
      {:ok, opts: ParserErrors.init([{:jsonrpc, {"/rpc", Renderer}} | @parsers])}
    end

    test "a well-formed JSON body parses", %{opts: opts} do
      conn = ParserErrors.call(post_to("/rpc", ~s({"id":1}), "application/json"), opts)

      refute conn.halted
      assert conn.body_params == %{"id" => 1}
    end

    test "a POST under the prefix that is not JSON is refused before parsing", %{opts: opts} do
      for type <- ["text/plain", nil] do
        conn = ParserErrors.call(post_to("/rpc", "not json", type), opts)

        assert conn.halted

        assert conn.private.refusal ==
                 {400, :parse_error, "Content-Type must be application/json"}
      end
    end

    test "a GET under the prefix is not gated", %{opts: opts} do
      conn = ParserErrors.call(conn(:get, "/rpc"), opts)

      refute conn.halted
    end

    test "an unparseable body is a generic parse error", %{opts: opts} do
      conn = ParserErrors.call(post_to("/rpc/x", ~s({"id":7,), "application/json"), opts)

      assert conn.halted
      assert conn.private.refusal == {400, :parse_error, "The request body is not parseable JSON"}
    end

    test "an oversized body is an invalid request", %{opts: opts} do
      body = ~s({"pad":") <> String.duplicate("a", 128) <> ~s("})
      conn = ParserErrors.call(post_to("/rpc", body, "application/json"), opts)

      assert conn.halted

      assert conn.private.refusal ==
               {413, :invalid_request, "The request body exceeds the size limit"}
    end

    test "every other path keeps Phoenix's behaviour", %{opts: opts} do
      assert_raise Plug.Parsers.ParseError, fn ->
        ParserErrors.call(post_to("/other", ~s({"broken":), "application/json"), opts)
      end

      assert_raise Plug.Parsers.RequestTooLargeError, fn ->
        body = ~s({"pad":") <> String.duplicate("a", 128) <> ~s("})
        ParserErrors.call(post_to("/other", body, "application/json"), opts)
      end

      conn = ParserErrors.call(post_to("/other", "plain words", "text/plain"), opts)
      refute conn.halted
    end

    test "the prefix is matched on the routed path, segment by segment", %{opts: opts} do
      # The router drops empty segments, so a doubled slash reaches the
      # prefix's routes and is gated like them.
      for url <- ["http://www.example.com//rpc", "http://www.example.com//rpc//x"] do
        conn = ParserErrors.call(post_to(url, "not json", "text/plain"), opts)

        assert conn.halted

        assert conn.private.refusal ==
                 {400, :parse_error, "Content-Type must be application/json"}
      end

      # A path that only begins with the prefix's letters is not under it.
      conn = ParserErrors.call(post_to("/rpc-other", "not json", "text/plain"), opts)
      refute conn.halted
    end
  end

  describe "a refused media type" do
    setup do
      opts =
        ParserErrors.init([
          {:jsonrpc, {"/rpc", Renderer}},
          {:refuse, {["multipart/*"], :multipart_refused}},
          {:errors, Plain}
          | @parsers
        ])

      {:ok, opts: opts}
    end

    test "under the prefix is answered 415 through its renderer, unread, closing the connection",
         %{opts: opts} do
      for method <- [:post, :put, :patch, :delete],
          url <- ["/rpc", "/rpc/x", "http://www.example.com//rpc"],
          type <- ["multipart/form-data; boundary=r8", "Multipart/Mixed; boundary=r8"] do
        conn = ParserErrors.call(counted(method, url, type), opts)

        assert conn.halted
        assert conn.private.refusal == {415, :parse_error, @refused_message}
        refute Map.has_key?(conn.private, :plain_refusal)
        assert get_resp_header(conn, "connection") == ["close"]
        refute_received {:body_read, _}
      end
    end

    test "elsewhere is answered 415 through the errors renderer with the reason, unread, " <>
           "closing the connection",
         %{opts: opts} do
      for method <- [:post, :put, :patch, :delete],
          url <- ["/other", "/rpc-other", "/"] do
        conn = ParserErrors.call(counted(method, url, "multipart/form-data; boundary=r8"), opts)

        assert conn.halted
        assert conn.private.plain_refusal == {415, :multipart_refused, nil}
        refute Map.has_key?(conn.private, :refusal)
        assert get_resp_header(conn, "connection") == ["close"]
        refute_received {:body_read, _}
      end
    end

    test "on HTTP/2, which has no connection header, neither refusal carries one",
         %{opts: opts} do
      for url <- ["/rpc", "/other"] do
        conn =
          :post
          |> counted(url, "multipart/form-data; boundary=r8")
          |> put_http_protocol(:"HTTP/2")
          |> ParserErrors.call(opts)

        assert conn.halted
        assert conn.status == 415
        assert get_resp_header(conn, "connection") == []
        refute_received {:body_read, _}
      end
    end

    test "is decided by the first content-type header, the one the parsers read", %{opts: opts} do
      first_json =
        :post
        |> conn("/other", ~s({"a":1}))
        |> Map.put(:req_headers, [
          {"content-type", "application/json"},
          {"content-type", "multipart/form-data; boundary=r8"}
        ])

      assert ParserErrors.call(first_json, opts).body_params == %{"a" => 1}

      first_multipart =
        :post
        |> conn("/other", ~s({"a":1}))
        |> Map.put(:req_headers, [
          {"content-type", "multipart/form-data; boundary=r8"},
          {"content-type", "application/json"}
        ])
        |> CountingBody.wrap()

      conn = ParserErrors.call(first_multipart, opts)
      assert conn.private.plain_refusal == {415, :multipart_refused, nil}
      refute_received {:body_read, _}
    end

    test "leaves alone what the parsers would not read, and every other type", %{opts: opts} do
      # A GET's body is not parsed, so there is nothing to refuse.
      conn = ParserErrors.call(counted(:get, "/other", "multipart/form-data; boundary=r8"), opts)
      refute conn.halted

      # Body params already in place are not read again (the test
      # adapter's own `multipart/mixed` map form).
      conn = ParserErrors.call(conn(:post, "/other", %{"a" => "b"}), opts)
      refute conn.halted
      assert conn.body_params == %{"a" => "b"}

      # A type outside the list reaches the parsers as before.
      conn = ParserErrors.call(counted(:post, "/other", "text/plain"), opts)
      refute conn.halted

      conn = ParserErrors.call(post_to("/other", ~s({"a":1}), "application/json"), opts)
      assert conn.body_params == %{"a" => 1}

      # An unparseable content type is no media type the list names.
      conn = ParserErrors.call(counted(:post, "/other", "multipart"), opts)
      refute conn.halted
      refute_received {:body_read, _}
    end

    test "a subtype names only itself" do
      opts =
        ParserErrors.init([
          {:refuse, {["multipart/form-data"], :multipart_refused}},
          {:errors, Plain} | @parsers
        ])

      conn = ParserErrors.call(counted(:post, "/x", "multipart/form-data; boundary=r8"), opts)
      assert conn.private.plain_refusal == {415, :multipart_refused, nil}

      conn = ParserErrors.call(counted(:post, "/x", "multipart/mixed; boundary=r8"), opts)
      refute conn.halted
    end

    test "is answered through CyfrWeb.ApiError by default, in its shape" do
      opts = ParserErrors.init([{:refuse, {["multipart/*"], :multipart_refused}} | @parsers])

      conn = ParserErrors.call(counted(:post, "/x", "multipart/form-data; boundary=r8"), opts)

      assert conn.halted
      assert conn.status == 415
      assert get_resp_header(conn, "connection") == ["close"]

      assert Jason.decode!(conn.resp_body) == %{
               "code" => "invalid_argument",
               "message" => "This endpoint takes no multipart bodies"
             }

      refute_received {:body_read, _}
    end
  end

  describe "without a JSON-RPC prefix" do
    setup do
      {:ok, opts: ParserErrors.init(@parsers)}
    end

    test "nothing is gated and every failure re-raises", %{opts: opts} do
      conn = ParserErrors.call(post_to("/mcp", "plain words", "text/plain"), opts)
      refute conn.halted

      assert_raise Plug.Parsers.ParseError, fn ->
        ParserErrors.call(post_to("/mcp", ~s({"broken":), "application/json"), opts)
      end
    end
  end

  test "a malformed jsonrpc option is refused at init" do
    for bad <- [
          "/rpc",
          {"/rpc"},
          {"rpc", Renderer},
          {"", Renderer},
          {:rpc, Renderer},
          {"/rpc", nil},
          {"/rpc", "Renderer"},
          {"/rpc", Renderer, :extra}
        ] do
      assert_raise ArgumentError, fn -> ParserErrors.init([{:jsonrpc, bad} | @parsers]) end
    end
  end

  test "a malformed refuse or errors option is refused at init" do
    for bad <- [
          "multipart/*",
          :multipart,
          ["multipart/*"],
          {[], :multipart_refused},
          {"multipart/*", :multipart_refused},
          {[:multipart], :multipart_refused},
          {["multipart"], :multipart_refused},
          {["Multipart/*"], :multipart_refused},
          {["*/*"], :multipart_refused},
          {["multipart/form-data; boundary=x"], :multipart_refused},
          {["multipart/*", nil], :multipart_refused},
          {["multipart/*"], nil},
          {["multipart/*"], "multipart_refused"},
          {["multipart/*"], :multipart_refused, :extra}
        ] do
      assert_raise ArgumentError, fn -> ParserErrors.init([{:refuse, bad} | @parsers]) end
    end

    for bad <- [nil, true, "CyfrWeb.ApiError", {Plain}] do
      assert_raise ArgumentError, fn -> ParserErrors.init([{:errors, bad} | @parsers]) end
    end

    opts =
      ParserErrors.init([
        {:refuse, {["multipart/*", "application/vnd.a+json"], :multipart_refused}},
        {:errors, Plain} | @parsers
      ])

    conn = ParserErrors.call(post_to("/x", "{}", "application/vnd.a+json"), opts)
    assert conn.private.plain_refusal == {415, :multipart_refused, nil}
  end
end
