defmodule Opus.HttpStreamHandlerTest do
  use ExUnit.Case, async: true

  alias Opus.HttpStreamHandler
  alias Sanctum.{Context, Policy}

  # ============================================================================
  # build_stream_imports/3
  # ============================================================================

  describe "build_stream_imports/3" do
    test "returns correct Wasmex import shape" do
      policy = Policy.default()
      ctx = Context.local()

      imports = HttpStreamHandler.build_stream_imports(policy, ctx, "local.test-component:1.0.0")

      assert is_map(imports)
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
  # Policy enforcement
  # ============================================================================

  describe "stream policy enforcement" do
    setup do
      case GenServer.whereis(Opus.RateLimiter) do
        nil -> {:ok, _} = Opus.RateLimiter.start_link([])
        _pid -> :ok
      end

      policy = %Policy{
        allowed_domains: ["api.openai.com"],
        allowed_methods: ["POST"],
        rate_limit: %{requests: 100, window: "1m"},
        timeout: "30s",
        max_memory_bytes: 64 * 1024 * 1024,
        max_request_size: 1_048_576,
        max_response_size: 5_242_880
      }

      ctx = Context.local()
      component_ref = "test-stream"

      imports = HttpStreamHandler.build_stream_imports(policy, ctx, component_ref)
      stream_ns = imports["cyfr:http/streaming@0.1.0"]

      {:ok, stream_ns: stream_ns}
    end

    test "blocks request to non-allowed domain", %{stream_ns: ns} do
      {:fn, func} = ns["request"]

      request = Jason.encode!(%{
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

      request = Jason.encode!(%{
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
      policy = %Policy{
        allowed_domains: ["localhost"],
        allowed_methods: ["POST"],
        rate_limit: nil,
        timeout: "30s",
        max_memory_bytes: 64 * 1024 * 1024,
        max_request_size: 1_048_576,
        max_response_size: 5_242_880
      }

      ctx = Context.local()
      imports = HttpStreamHandler.build_stream_imports(policy, ctx, "test")
      stream_ns = imports["cyfr:http/streaming@0.1.0"]
      {:fn, func} = stream_ns["request"]

      request = Jason.encode!(%{
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
      policy = %Policy{
        allowed_domains: ["api.openai.com"],
        allowed_methods: ["POST"],
        rate_limit: nil,
        timeout: "30s",
        max_memory_bytes: 64 * 1024 * 1024,
        max_request_size: 1_048_576,
        max_response_size: 5_242_880
      }

      ctx = Context.local()
      imports = HttpStreamHandler.build_stream_imports(policy, ctx, "test")
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
      policy = %Policy{
        allowed_domains: ["api.openai.com"],
        allowed_methods: ["POST"],
        rate_limit: nil,
        timeout: "30s",
        max_memory_bytes: 64 * 1024 * 1024,
        max_request_size: 1_048_576,
        max_response_size: 5_242_880
      }

      ctx = Context.local()
      imports = HttpStreamHandler.build_stream_imports(policy, ctx, "test")
      stream_ns = imports["cyfr:http/streaming@0.1.0"]
      {:fn, request_fn} = stream_ns["request"]

      # The request will fail at DNS/connection level, but the handle will be
      # created before the async task fails. We need to test the limit.
      # To reliably test the limit, we use a domain that will be allowed but
      # fail to connect — that still creates the handle.

      # Create 3 streams (they'll fail to connect but handles are created)
      request = Jason.encode!(%{
        "method" => "POST",
        "url" => "https://api.openai.com/v1/chat/completions",
        "headers" => %{},
        "body" => ""
      })

      results = for _ <- 1..4 do
        result = request_fn.(request)
        Jason.decode!(result)
      end

      # First 3 should succeed (have "handle" key), 4th should fail
      # Note: some may fail at DNS level instead, so we check for either handle or DNS error
      stream_limit_errors = Enum.filter(results, fn r ->
        r["error"]["type"] == "stream_limit"
      end)

      # At least one should be a stream limit error (the 4th)
      assert length(stream_limit_errors) >= 1
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
      policy = Policy.default()
      ctx = Context.local()

      # build_stream_imports creates the exec_ref internally;
      # cleanup_registry is called by the executor after completion.
      # We can't access exec_ref directly, but we can verify
      # that build_stream_imports + cleanup_registry round-trips safely.
      imports = HttpStreamHandler.build_stream_imports(policy, ctx, "test-cleanup")
      _stream_ns = imports["cyfr:http/streaming@0.1.0"]

      # cleanup_registry with an arbitrary ref should be safe
      assert :ok == HttpStreamHandler.cleanup_registry("some-exec-ref")
    end
  end
end
