defmodule Opus.HttpHandlerTest do
  use ExUnit.Case, async: true

  alias Opus.HttpHandler
  alias Sanctum.{Context, Policy}

  # ============================================================================
  # private_ip?/1
  # ============================================================================

  describe "private_ip?/1" do
    test "blocks loopback 127.0.0.1" do
      assert HttpHandler.private_ip?({127, 0, 0, 1})
    end

    test "blocks loopback range 127.x.x.x" do
      assert HttpHandler.private_ip?({127, 255, 255, 255})
      assert HttpHandler.private_ip?({127, 0, 0, 2})
    end

    test "blocks 10.0.0.0/8 private range" do
      assert HttpHandler.private_ip?({10, 0, 0, 1})
      assert HttpHandler.private_ip?({10, 255, 255, 255})
      assert HttpHandler.private_ip?({10, 10, 10, 10})
    end

    test "blocks 172.16.0.0/12 private range" do
      assert HttpHandler.private_ip?({172, 16, 0, 1})
      assert HttpHandler.private_ip?({172, 31, 255, 255})
      assert HttpHandler.private_ip?({172, 20, 5, 3})
    end

    test "allows 172.15.x.x (outside /12 range)" do
      refute HttpHandler.private_ip?({172, 15, 255, 255})
    end

    test "allows 172.32.x.x (outside /12 range)" do
      refute HttpHandler.private_ip?({172, 32, 0, 1})
    end

    test "blocks 192.168.0.0/16 private range" do
      assert HttpHandler.private_ip?({192, 168, 0, 1})
      assert HttpHandler.private_ip?({192, 168, 255, 255})
      assert HttpHandler.private_ip?({192, 168, 1, 100})
    end

    test "blocks 169.254.0.0/16 link-local / AWS metadata" do
      assert HttpHandler.private_ip?({169, 254, 169, 254})
      assert HttpHandler.private_ip?({169, 254, 0, 1})
    end

    test "blocks 0.0.0.0/8" do
      assert HttpHandler.private_ip?({0, 0, 0, 0})
      assert HttpHandler.private_ip?({0, 0, 0, 1})
    end

    test "allows public IP 8.8.8.8" do
      refute HttpHandler.private_ip?({8, 8, 8, 8})
    end

    test "allows public IP 1.1.1.1" do
      refute HttpHandler.private_ip?({1, 1, 1, 1})
    end

    test "allows public IP 93.184.216.34" do
      refute HttpHandler.private_ip?({93, 184, 216, 34})
    end

    test "allows public IP 203.0.113.1" do
      refute HttpHandler.private_ip?({203, 0, 113, 1})
    end
  end

  # ============================================================================
  # private_ip?/1 - IPv6
  # ============================================================================

  describe "private_ip?/1 IPv6" do
    test "blocks IPv6 loopback ::1" do
      assert HttpHandler.private_ip?({0, 0, 0, 0, 0, 0, 0, 1})
    end

    test "blocks IPv6 unspecified ::" do
      assert HttpHandler.private_ip?({0, 0, 0, 0, 0, 0, 0, 0})
    end

    test "blocks IPv6 unique local fc00::/7" do
      assert HttpHandler.private_ip?({0xFC00, 0, 0, 0, 0, 0, 0, 1})
      assert HttpHandler.private_ip?({0xFD00, 0, 0, 0, 0, 0, 0, 1})
      assert HttpHandler.private_ip?({0xFDFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF})
    end

    test "blocks IPv6 link-local fe80::/10" do
      assert HttpHandler.private_ip?({0xFE80, 0, 0, 0, 0, 0, 0, 1})
      assert HttpHandler.private_ip?({0xFEBF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF})
    end

    test "blocks IPv4-mapped IPv6 with private IPv4 (::ffff:127.0.0.1)" do
      # ::ffff:127.0.0.1 = {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001}
      assert HttpHandler.private_ip?({0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001})
    end

    test "blocks IPv4-mapped IPv6 with private 10.x (::ffff:10.0.0.1)" do
      # ::ffff:10.0.0.1 = {0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0001}
      assert HttpHandler.private_ip?({0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0001})
    end

    test "allows IPv4-mapped IPv6 with public IPv4 (::ffff:8.8.8.8)" do
      # ::ffff:8.8.8.8 = {0, 0, 0, 0, 0, 0xFFFF, 0x0808, 0x0808}
      refute HttpHandler.private_ip?({0, 0, 0, 0, 0, 0xFFFF, 0x0808, 0x0808})
    end

    test "allows public IPv6 (2001:db8::1)" do
      refute HttpHandler.private_ip?({0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1})
    end

    test "allows public IPv6 (2606:4700::1)" do
      refute HttpHandler.private_ip?({0x2606, 0x4700, 0, 0, 0, 0, 0, 1})
    end

    test "does not block fe00:: (outside fe80::/10)" do
      refute HttpHandler.private_ip?({0xFE00, 0, 0, 0, 0, 0, 0, 1})
    end

    test "does not block fec0:: (outside fe80::/10)" do
      refute HttpHandler.private_ip?({0xFEC0, 0, 0, 0, 0, 0, 0, 1})
    end
  end

  # ============================================================================
  # resolve_and_validate_ip/1
  # ============================================================================

  describe "resolve_and_validate_ip/1" do
    test "resolves public hostname successfully" do
      # Use a well-known public hostname
      case HttpHandler.resolve_and_validate_ip("one.one.one.one") do
        {:ok, ip_string} ->
          assert is_binary(ip_string)
          # Should be Cloudflare's IP
          assert ip_string =~ ~r/^\d+\.\d+\.\d+\.\d+$/

        {:error, :dns_error, _msg} ->
          # DNS may not be available in CI
          :ok
      end
    end

    test "blocks localhost resolution" do
      assert {:error, :private_ip_blocked, msg} =
               HttpHandler.resolve_and_validate_ip("localhost")

      assert msg =~ "private IP"
      assert msg =~ "127.0.0.1"
    end

    test "returns dns_error for non-existent domain" do
      assert {:error, :dns_error, msg} =
               HttpHandler.resolve_and_validate_ip("this-domain-does-not-exist-cyfr-test.invalid")

      assert msg =~ "DNS resolution failed"
    end
  end

  # ============================================================================
  # execute/4 - policy enforcement
  # ============================================================================

  describe "execute/4 policy enforcement" do
    setup do
      # Start rate limiter since it's no longer in the supervision tree
      case GenServer.whereis(Opus.RateLimiter) do
        nil -> {:ok, _} = Opus.RateLimiter.start_link([])
        _pid -> :ok
      end

      policy = %Policy{
        allowed_domains: ["api.stripe.com", "*.example.com"],
        allowed_methods: ["GET", "POST"],
        rate_limit: %{requests: 100, window: "1m"},
        timeout: "30s",
        max_memory_bytes: 64 * 1024 * 1024,
        max_request_size: 1024,
        max_response_size: 4096
      }

      ctx = Context.local()
      component_ref = "local.test-catalyst:1.0.0"

      {:ok, policy: policy, ctx: ctx, component_ref: component_ref}
    end

    test "blocks request to non-allowed domain", %{policy: policy, ctx: ctx, component_ref: ref} do
      request = Jason.encode!(%{
        "method" => "GET",
        "url" => "https://evil.com/steal-data",
        "headers" => %{},
        "body" => ""
      })

      result = HttpHandler.execute(request, policy, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "domain_blocked"
    end

    test "blocks request with disallowed method", %{policy: policy, ctx: ctx, component_ref: ref} do
      request = Jason.encode!(%{
        "method" => "DELETE",
        "url" => "https://api.stripe.com/v1/charges",
        "headers" => %{},
        "body" => ""
      })

      result = HttpHandler.execute(request, policy, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "method_blocked"
    end

    test "blocks request with oversized body", %{policy: policy, ctx: ctx, component_ref: ref} do
      large_body = String.duplicate("x", 2048)

      request = Jason.encode!(%{
        "method" => "POST",
        "url" => "https://api.stripe.com/v1/charges",
        "headers" => %{},
        "body" => large_body
      })

      result = HttpHandler.execute(request, policy, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "request_too_large"
      assert decoded["error"]["message"] =~ "exceeds limit"
    end

    test "returns error for invalid JSON request", %{policy: policy, ctx: ctx, component_ref: ref} do
      result = HttpHandler.execute("not-json", policy, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "http_error"
      assert decoded["error"]["message"] =~ "Invalid JSON"
    end

    test "returns error for request missing required fields", %{policy: policy, ctx: ctx, component_ref: ref} do
      request = Jason.encode!(%{"url" => "https://api.stripe.com"})
      result = HttpHandler.execute(request, policy, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "http_error"
      assert decoded["error"]["message"] =~ "must include"
    end

    test "returns error for request with invalid URL", %{policy: policy, ctx: ctx, component_ref: ref} do
      request = Jason.encode!(%{"method" => "GET", "url" => "not-a-url"})
      result = HttpHandler.execute(request, policy, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "http_error"
      assert decoded["error"]["message"] =~ "missing hostname"
    end

    test "blocks request to private IP (localhost)", %{policy: policy, ctx: ctx, component_ref: ref} do
      # Add localhost to allowed domains so we get past domain check
      policy = %{policy | allowed_domains: ["localhost"]}

      request = Jason.encode!(%{
        "method" => "GET",
        "url" => "http://localhost/admin",
        "headers" => %{},
        "body" => ""
      })

      result = HttpHandler.execute(request, policy, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "private_ip_blocked"
      assert decoded["error"]["message"] =~ "127.0.0.1"
    end
  end

  # ============================================================================
  # build_http_imports/3
  # ============================================================================

  describe "build_http_imports/3" do
    test "returns correct Wasmex import shape" do
      policy = Policy.default()
      ctx = Context.local()

      imports = HttpHandler.build_http_imports(policy, ctx, "local.test-component:1.0.0")

      assert is_map(imports)
      assert Map.has_key?(imports, "cyfr:http/fetch@0.1.0")

      fetch_ns = imports["cyfr:http/fetch@0.1.0"]
      assert Map.has_key?(fetch_ns, "request")

      {:fn, func} = fetch_ns["request"]
      assert is_function(func, 1)
    end

    test "returned function is callable and returns JSON" do
      policy = %Policy{
        allowed_domains: ["blocked-only.test"],
        allowed_methods: ["GET"],
        rate_limit: nil,
        timeout: "30s",
        max_memory_bytes: 64 * 1024 * 1024,
        max_request_size: 1_048_576,
        max_response_size: 5_242_880
      }

      ctx = Context.local()
      imports = HttpHandler.build_http_imports(policy, ctx, "local.test-component:1.0.0")

      {:fn, func} = imports["cyfr:http/fetch@0.1.0"]["request"]

      # Call with a blocked domain to verify it works end-to-end
      request = Jason.encode!(%{
        "method" => "GET",
        "url" => "https://evil.com/data",
        "headers" => %{},
        "body" => ""
      })

      result = func.(request)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "domain_blocked"
    end
  end

  # ============================================================================
  # execute/4 - base64 body encoding
  # ============================================================================

  describe "execute/4 base64 body encoding" do
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
        max_request_size: 1024,
        max_response_size: 4096
      }

      ctx = Context.local()
      component_ref = "local.test-catalyst-b64:1.0.0"

      {:ok, policy: policy, ctx: ctx, component_ref: component_ref}
    end

    test "rejects invalid base64 body", %{policy: policy, ctx: ctx, component_ref: ref} do
      request = Jason.encode!(%{
        "method" => "POST",
        "url" => "https://api.openai.com/v1/audio/speech",
        "headers" => %{},
        "body" => "not-valid-base64!!!",
        "body_encoding" => "base64"
      })

      result = HttpHandler.execute(request, policy, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "http_error"
      assert decoded["error"]["message"] =~ "Invalid base64"
    end

    test "validates decoded body size against policy limit", %{policy: policy, ctx: ctx, component_ref: ref} do
      # Create base64 content that decodes to > 1024 bytes
      large_binary = String.duplicate("x", 2048)
      encoded = Base.encode64(large_binary)

      request = Jason.encode!(%{
        "method" => "POST",
        "url" => "https://api.openai.com/v1/audio/speech",
        "headers" => %{},
        "body" => encoded,
        "body_encoding" => "base64"
      })

      result = HttpHandler.execute(request, policy, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "request_too_large"
    end
  end

  # ============================================================================
  # execute/4 - multipart support
  # ============================================================================

  describe "execute/4 multipart" do
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
        max_request_size: 1024,
        max_response_size: 4096
      }

      ctx = Context.local()
      component_ref = "local.test-catalyst-mp:1.0.0"

      {:ok, policy: policy, ctx: ctx, component_ref: component_ref}
    end

    test "rejects request with both body and multipart", %{policy: policy, ctx: ctx, component_ref: ref} do
      request = Jason.encode!(%{
        "method" => "POST",
        "url" => "https://api.openai.com/v1/audio/transcriptions",
        "headers" => %{},
        "body" => "some body",
        "multipart" => [
          %{"name" => "model", "value" => "whisper-1"}
        ]
      })

      result = HttpHandler.execute(request, policy, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "http_error"
      assert decoded["error"]["message"] =~ "both 'body' and 'multipart'"
    end

    test "rejects multipart with invalid base64 data", %{policy: policy, ctx: ctx, component_ref: ref} do
      request = Jason.encode!(%{
        "method" => "POST",
        "url" => "https://api.openai.com/v1/audio/transcriptions",
        "headers" => %{},
        "multipart" => [
          %{"name" => "file", "filename" => "audio.mp3", "content_type" => "audio/mpeg", "data" => "not-valid!!!"},
          %{"name" => "model", "value" => "whisper-1"}
        ]
      })

      result = HttpHandler.execute(request, policy, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "http_error"
      assert decoded["error"]["message"] =~ "Invalid base64"
    end

    test "validates multipart total decoded size against policy", %{policy: policy, ctx: ctx, component_ref: ref} do
      # Create file content that exceeds 1024 byte limit
      large_file = String.duplicate("x", 2048)
      encoded = Base.encode64(large_file)

      request = Jason.encode!(%{
        "method" => "POST",
        "url" => "https://api.openai.com/v1/audio/transcriptions",
        "headers" => %{},
        "multipart" => [
          %{"name" => "file", "filename" => "audio.mp3", "content_type" => "audio/mpeg", "data" => encoded},
          %{"name" => "model", "value" => "whisper-1"}
        ]
      })

      result = HttpHandler.execute(request, policy, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "request_too_large"
      assert decoded["error"]["message"] =~ "Multipart body"
    end

    test "rejects multipart part without name", %{policy: policy, ctx: ctx, component_ref: ref} do
      request = Jason.encode!(%{
        "method" => "POST",
        "url" => "https://api.openai.com/v1/audio/transcriptions",
        "headers" => %{},
        "multipart" => [
          %{"value" => "whisper-1"}
        ]
      })

      result = HttpHandler.execute(request, policy, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "http_error"
      assert decoded["error"]["message"] =~ "must include 'name'"
    end
  end

  # ============================================================================
  # encode_response_base64/3
  # ============================================================================

  describe "encode_response_base64/3" do
    test "returns valid JSON with base64-encoded body" do
      result = HttpHandler.encode_response_base64(200, [{"content-type", "audio/mpeg"}], "binary audio data")
      decoded = Jason.decode!(result)

      assert decoded["status"] == 200
      assert decoded["body_encoding"] == "base64"
      assert decoded["headers"]["content-type"] == "audio/mpeg"
      assert Base.decode64!(decoded["body"]) == "binary audio data"
    end
  end

  # ============================================================================
  # encode_error/2 and encode_response/3
  # ============================================================================

  describe "encode_error/2" do
    test "returns valid JSON with error structure" do
      result = HttpHandler.encode_error(:domain_blocked, "not allowed")
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "domain_blocked"
      assert decoded["error"]["message"] == "not allowed"
    end
  end

  describe "encode_response/3" do
    test "returns valid JSON with response structure" do
      result = HttpHandler.encode_response(200, [{"content-type", "application/json"}], "{}")
      decoded = Jason.decode!(result)

      assert decoded["status"] == 200
      assert decoded["headers"]["content-type"] == "application/json"
      assert decoded["body"] == "{}"
    end
  end
end
