# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.Plugs.ParserErrorsTest do
  @moduledoc """
  `Plug.Parsers` with one path prefix's failures answered through the
  renderer the caller names, and Phoenix's behaviour everywhere else.
  The endpoint's own `/mcp` wiring is exercised end to end in
  `EmissaryWeb.MCPErrorTest`.
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

  @parsers [parsers: [:json], pass: ["*/*"], json_decoder: Phoenix.json_library(), length: 64]

  defp post_to(path, body, content_type) do
    conn = conn(:post, path, body)
    if content_type, do: put_req_header(conn, "content-type", content_type), else: conn
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
end
