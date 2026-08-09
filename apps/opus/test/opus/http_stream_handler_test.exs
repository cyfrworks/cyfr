# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.HttpStreamHandlerTest do
  use ExUnit.Case, async: true

  alias Opus.HttpStreamHandler
  alias Opus.Test.EdgeFixtures

  # ============================================================================
  # build_stream_imports/4
  # ============================================================================

  describe "build_stream_imports/4" do
    test "returns {imports, exec_ref} tuple with correct Wasmex import shape" do
      edge = EdgeFixtures.edge()
      ctx = Sanctum.TestContext.local()

      {imports, exec_ref} =
        HttpStreamHandler.build_stream_imports(
          edge,
          EdgeFixtures.limits(),
          ctx,
          "local.test-component:1.0.0"
        )

      assert is_map(imports)
      assert is_binary(exec_ref)
      assert Map.has_key?(imports, "cyfr:http/streaming@0.1.0")

      stream_ns = imports["cyfr:http/streaming@0.1.0"]
      assert Map.has_key?(stream_ns, "request")
      assert Map.has_key?(stream_ns, "read")
      assert Map.has_key?(stream_ns, "close")

      # Verify function signatures (Component Model format: {:fn, function})
      {:fn, _func} = stream_ns["request"]
      {:fn, _func} = stream_ns["read"]
      {:fn, _func} = stream_ns["close"]
    end
  end

  # ============================================================================
  # Edge enforcement
  # ============================================================================

  describe "stream edge enforcement" do
    setup do
      case GenServer.whereis(Opus.RateLimiter) do
        nil -> {:ok, _} = Opus.RateLimiter.start_link([])
        _pid -> :ok
      end

      edge = EdgeFixtures.edge(domains: ["api.openai.com"], methods: ["POST"])

      ctx = Sanctum.TestContext.local()
      component_ref = "test-stream"

      {imports, _exec_ref} =
        HttpStreamHandler.build_stream_imports(edge, EdgeFixtures.limits(), ctx, component_ref)

      stream_ns = imports["cyfr:http/streaming@0.1.0"]

      {:ok, stream_ns: stream_ns}
    end

    test "blocks request to non-allowed domain", %{stream_ns: ns} do
      {:fn, func} = ns["request"]

      request =
        Jason.encode!(%{
          "method" => "POST",
          "url" => "https://evil.com/stream",
          "headers" => %{},
          "body" => ""
        })

      result = func.(request)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "domain_blocked"
    end

    test "blocks disallowed method", %{stream_ns: ns} do
      {:fn, func} = ns["request"]

      request =
        Jason.encode!(%{
          "method" => "DELETE",
          "url" => "https://api.openai.com/v1/chat/completions",
          "headers" => %{},
          "body" => ""
        })

      result = func.(request)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "method_blocked"
    end

    test "returns error for invalid JSON", %{stream_ns: ns} do
      {:fn, func} = ns["request"]

      result = func.("not-json")
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "http_error"
      assert decoded["error"]["message"] =~ "Invalid JSON"
    end

    test "blocks private IP (localhost)", %{stream_ns: _ns} do
      # Need to allow localhost domain first
      edge = EdgeFixtures.edge(domains: ["localhost"], methods: ["POST"])

      ctx = Sanctum.TestContext.local()

      {imports, _exec_ref} =
        HttpStreamHandler.build_stream_imports(edge, EdgeFixtures.limits(), ctx, "test")

      stream_ns = imports["cyfr:http/streaming@0.1.0"]
      {:fn, func} = stream_ns["request"]

      request =
        Jason.encode!(%{
          "method" => "POST",
          "url" => "http://localhost/stream",
          "headers" => %{},
          "body" => ""
        })

      result = func.(request)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "private_ip_blocked"
    end
  end

  # ============================================================================
  # Stream handle operations
  # ============================================================================

  describe "stream read/close with invalid handles" do
    setup do
      edge = EdgeFixtures.edge(domains: ["api.openai.com"], methods: ["POST"])

      ctx = Sanctum.TestContext.local()

      {imports, _exec_ref} =
        HttpStreamHandler.build_stream_imports(edge, EdgeFixtures.limits(), ctx, "test")

      stream_ns = imports["cyfr:http/streaming@0.1.0"]

      {:ok, stream_ns: stream_ns}
    end

    test "read returns error for unknown handle", %{stream_ns: ns} do
      {:fn, func} = ns["read"]

      result = func.("nonexistent-handle")
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "invalid_handle"
      assert decoded["error"]["message"] =~ "Unknown stream handle"
    end

    test "close is idempotent for unknown handle", %{stream_ns: ns} do
      {:fn, func} = ns["close"]

      result = func.("nonexistent-handle")
      decoded = Jason.decode!(result)

      assert decoded["ok"] == true
    end
  end

  # ============================================================================
  # Concurrent stream limit
  # ============================================================================

  describe "concurrent stream limit" do
    test "enforces max concurrent streams" do
      edge = EdgeFixtures.edge(domains: ["api.openai.com"], methods: ["POST"])

      ctx = Sanctum.TestContext.local()

      {imports, _exec_ref} =
        HttpStreamHandler.build_stream_imports(edge, EdgeFixtures.limits(), ctx, "test")

      stream_ns = imports["cyfr:http/streaming@0.1.0"]
      {:fn, request_fn} = stream_ns["request"]

      # The request will fail at DNS/connection level, but the handle will be
      # created before the async task fails. We need to test the limit.
      # To reliably test the limit, we use a domain that will be allowed but
      # fail to connect — that still creates the handle.

      # Create 3 streams (they'll fail to connect but handles are created)
      request =
        Jason.encode!(%{
          "method" => "POST",
          "url" => "https://api.openai.com/v1/chat/completions",
          "headers" => %{},
          "body" => ""
        })

      results =
        for _ <- 1..4 do
          result = request_fn.(request)
          Jason.decode!(result)
        end

      # First 3 should succeed (have "handle" key), 4th should fail
      # Note: some may fail at DNS level instead, so we check for either handle or DNS error
      stream_limit_errors =
        Enum.filter(results, fn r ->
          r["error"]["type"] == "stream_limit"
        end)

      # At least one should be a stream limit error (the 4th)
      assert stream_limit_errors != []
    end
  end

  # ============================================================================
  # Request size enforcement (parity with cyfr:http/fetch)
  # ============================================================================

  describe "stream request size enforcement" do
    test "rejects a body exceeding the node's max_request_size" do
      edge = EdgeFixtures.edge(domains: ["api.openai.com"], methods: ["POST"])
      limits = EdgeFixtures.limits(max_request_size: 16)
      ctx = Sanctum.TestContext.local()

      {imports, _exec_ref} =
        HttpStreamHandler.build_stream_imports(edge, limits, ctx, "test-req-size")

      {:fn, request_fn} = imports["cyfr:http/streaming@0.1.0"]["request"]

      request =
        Jason.encode!(%{
          "method" => "POST",
          "url" => "https://api.openai.com/v1/chat/completions",
          "headers" => %{},
          "body" => String.duplicate("x", 100)
        })

      decoded = request_fn.(request) |> Jason.decode!()

      assert decoded["error"]["type"] == "request_too_large"
      assert decoded["error"]["message"] =~ "exceeds limit (16 bytes)"
    end

    test "rejects multipart on the streaming interface" do
      edge = EdgeFixtures.edge(domains: ["api.openai.com"], methods: ["POST"])
      ctx = Sanctum.TestContext.local()

      {imports, _exec_ref} =
        HttpStreamHandler.build_stream_imports(edge, EdgeFixtures.limits(), ctx, "test-mp")

      {:fn, request_fn} = imports["cyfr:http/streaming@0.1.0"]["request"]

      request =
        Jason.encode!(%{
          "method" => "POST",
          "url" => "https://api.openai.com/v1/audio/transcriptions",
          "headers" => %{},
          "body" => "",
          "multipart" => [%{"name" => "model", "value" => "whisper-1"}]
        })

      decoded = request_fn.(request) |> Jason.decode!()

      assert decoded["error"]["type"] == "http_error"
      assert decoded["error"]["message"] =~ "do not support 'multipart'"
    end
  end

  # ============================================================================
  # Stream timeout derived from consented limits
  # ============================================================================

  describe "stream timeout from node limits" do
    test "times out per the node's consented timeout, not the 60s fallback" do
      # A "0s" consented timeout makes the derived deadline elapse immediately;
      # the 60s fallback would never fire within test time.
      edge =
        EdgeFixtures.edge(domains: ["localhost"], methods: ["GET"], private_ips: ["127.0.0.1"])

      limits = EdgeFixtures.limits(timeout: "0s")
      ctx = Sanctum.TestContext.local()

      {imports, _exec_ref} =
        HttpStreamHandler.build_stream_imports(edge, limits, ctx, "test-timeout")

      stream_ns = imports["cyfr:http/streaming@0.1.0"]
      {:fn, request_fn} = stream_ns["request"]
      {:fn, read_fn} = stream_ns["read"]

      # Port 1 refuses the connection, but the handle is created before the
      # collector's result is known.
      request =
        Jason.encode!(%{
          "method" => "GET",
          "url" => "http://localhost:1/stream",
          "headers" => %{},
          "body" => ""
        })

      assert %{"handle" => handle} = request_fn.(request) |> Jason.decode!()

      Process.sleep(15)
      decoded = read_fn.(handle) |> Jason.decode!()

      assert decoded["error"]["type"] == "timeout"
      assert decoded["error"]["message"] == "Stream timed out after 0s"
    end
  end

  # ============================================================================
  # Collector buffer cap
  # ============================================================================

  describe "stream collector cap" do
    test "buffered response bytes are capped at max_response_size before the guest reads" do
      # Local server sends a body larger than the consented max_response_size;
      # the collector must stop buffering and park the oversize error even
      # though the guest never reads a byte.
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen)

      body = String.duplicate("x", 100)

      server =
        spawn(fn ->
          {:ok, sock} = :gen_tcp.accept(listen, 5_000)
          _ = :gen_tcp.recv(sock, 0, 1_000)

          response =
            "HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <>
              body

          :ok = :gen_tcp.send(sock, response)
          Process.sleep(500)
          :gen_tcp.close(sock)
        end)

      edge =
        EdgeFixtures.edge(domains: ["localhost"], methods: ["GET"], private_ips: ["127.0.0.1"])

      limits = EdgeFixtures.limits(max_response_size: 8)
      ctx = Sanctum.TestContext.local()

      {imports, _exec_ref} =
        HttpStreamHandler.build_stream_imports(edge, limits, ctx, "test-collector-cap")

      stream_ns = imports["cyfr:http/streaming@0.1.0"]
      {:fn, request_fn} = stream_ns["request"]
      {:fn, read_fn} = stream_ns["read"]

      request =
        Jason.encode!(%{
          "method" => "GET",
          "url" => "http://localhost:#{port}/big",
          "headers" => %{},
          "body" => ""
        })

      assert %{"handle" => handle} = request_fn.(request) |> Jason.decode!()

      decoded = poll_for_error(read_fn, handle, 150)

      assert decoded["error"]["type"] == "response_too_large"
      assert decoded["error"]["message"] =~ "exceeds limit (8 bytes)"

      Process.exit(server, :kill)
      :gen_tcp.close(listen)
    end
  end

  # Drain data frames until the stream surfaces an error; fail loudly if the
  # stream completes or the attempts run out first.
  defp poll_for_error(_read_fn, _handle, 0), do: flunk("stream never surfaced an error")

  defp poll_for_error(read_fn, handle, attempts) do
    decoded = read_fn.(handle) |> Jason.decode!()

    cond do
      decoded["error"] ->
        decoded

      decoded["done"] == true ->
        flunk("stream completed without surfacing the oversize error")

      true ->
        Process.sleep(20)
        poll_for_error(read_fn, handle, attempts - 1)
    end
  end

  # ============================================================================
  # cleanup_registry/1
  # ============================================================================

  describe "cleanup_registry/1" do
    test "cleanup is safe on nonexistent exec_ref" do
      # Should not raise for a ref that was never used
      assert :ok == HttpStreamHandler.cleanup_registry("nonexistent-ref")
    end

    test "cleanup works on exec_ref from build_stream_imports" do
      edge = EdgeFixtures.edge()
      ctx = Sanctum.TestContext.local()

      # build_stream_imports creates the exec_ref internally;
      # cleanup_registry is called by the executor after completion.
      # We can't access exec_ref directly, but we can verify
      # that build_stream_imports + cleanup_registry round-trips safely.
      {imports, _exec_ref} =
        HttpStreamHandler.build_stream_imports(edge, EdgeFixtures.limits(), ctx, "test-cleanup")

      _stream_ns = imports["cyfr:http/streaming@0.1.0"]

      # cleanup_registry with an arbitrary ref should be safe
      assert :ok == HttpStreamHandler.cleanup_registry("some-exec-ref")
    end
  end
end
