# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.HttpHandlerTest do
  use ExUnit.Case, async: true

  alias Opus.HttpHandler
  alias Opus.Test.EdgeFixtures

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

      assert HttpHandler.private_ip?(
               {0xFDFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF}
             )
    end

    test "blocks IPv6 link-local fe80::/10" do
      assert HttpHandler.private_ip?({0xFE80, 0, 0, 0, 0, 0, 0, 1})

      assert HttpHandler.private_ip?(
               {0xFEBF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF}
             )
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
  # private_ip?/1 delegation — the range policy lives in Cyfr.Network
  # ============================================================================

  describe "private_ip?/1 delegates to Cyfr.Network.private_ip?/1" do
    test "RFC1918 denial passes through Cyfr.Network" do
      assert Cyfr.Network.private_ip?({10, 0, 0, 1})
      assert HttpHandler.private_ip?({10, 0, 0, 1}) == Cyfr.Network.private_ip?({10, 0, 0, 1})
    end

    test "loopback denial passes through Cyfr.Network" do
      assert Cyfr.Network.private_ip?({127, 0, 0, 1})
      assert HttpHandler.private_ip?({127, 0, 0, 1}) == Cyfr.Network.private_ip?({127, 0, 0, 1})
    end

    test "link-local / metadata denial passes through Cyfr.Network" do
      assert Cyfr.Network.private_ip?({169, 254, 169, 254})

      assert HttpHandler.private_ip?({169, 254, 169, 254}) ==
               Cyfr.Network.private_ip?({169, 254, 169, 254})
    end

    test "IPv4-mapped IPv6 denial passes through Cyfr.Network" do
      # ::ffff:10.0.0.1
      mapped = {0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0001}
      assert Cyfr.Network.private_ip?(mapped)
      assert HttpHandler.private_ip?(mapped) == Cyfr.Network.private_ip?(mapped)
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
  # resolve_and_validate_ip/2 with edge private_ips
  # ============================================================================

  describe "resolve_and_validate_ip/2 with allowed_private_ips" do
    test "allows private IP when listed on the edge" do
      edge = EdgeFixtures.edge(private_ips: ["127.0.0.1"])

      assert {:ok, "127.0.0.1"} = HttpHandler.resolve_and_validate_ip("localhost", edge)
    end

    test "blocks private IP not in the edge allowlist" do
      edge = EdgeFixtures.edge(private_ips: ["10.0.0.1"])

      assert {:error, :private_ip_blocked, _msg} =
               HttpHandler.resolve_and_validate_ip("localhost", edge)
    end

    test "allows private IP matching CIDR range on the edge" do
      edge = EdgeFixtures.edge(private_ips: ["127.0.0.0/8"])

      assert {:ok, "127.0.0.1"} = HttpHandler.resolve_and_validate_ip("localhost", edge)
    end

    test "always blocks 169.254.x.x even when explicitly allowed" do
      edge = EdgeFixtures.edge(private_ips: ["169.254.0.0/16", "169.254.169.254"])

      assert {:error, :private_ip_blocked, _msg} =
               HttpHandler.resolve_and_validate_ip("169.254.169.254", edge)
    end

    test "empty allowed_private_ips preserves default blocking" do
      edge = EdgeFixtures.edge(private_ips: [])

      assert {:error, :private_ip_blocked, _msg} =
               HttpHandler.resolve_and_validate_ip("localhost", edge)
    end

    test "nil edge preserves default blocking" do
      assert {:error, :private_ip_blocked, _msg} =
               HttpHandler.resolve_and_validate_ip("localhost", nil)
    end

    test "public IPs are unaffected by the allowlist" do
      edge = EdgeFixtures.edge(private_ips: [])

      case HttpHandler.resolve_and_validate_ip("one.one.one.one", edge) do
        {:ok, ip_string} ->
          assert is_binary(ip_string)

        {:error, :dns_error, _msg} ->
          # DNS may not be available in CI
          :ok
      end
    end
  end

  # ============================================================================
  # execute/5 - edge enforcement
  # ============================================================================

  describe "execute/5 edge enforcement" do
    setup do
      # Start rate limiter since it's no longer in the supervision tree
      case GenServer.whereis(Opus.RateLimiter) do
        nil -> {:ok, _} = Opus.RateLimiter.start_link([])
        _pid -> :ok
      end

      edge =
        EdgeFixtures.edge(domains: ["api.stripe.com", "*.example.com"], methods: ["GET", "POST"])

      limits = EdgeFixtures.limits(max_request_size: 1024, max_response_size: 4096)

      ctx = Sanctum.TestContext.local()
      component_ref = "local.test-catalyst:1.0.0"

      {:ok, edge: edge, limits: limits, ctx: ctx, component_ref: component_ref}
    end

    test "blocks request to non-allowed domain", %{
      edge: edge,
      limits: limits,
      ctx: ctx,
      component_ref: ref
    } do
      request =
        Jason.encode!(%{
          "method" => "GET",
          "url" => "https://evil.com/steal-data",
          "headers" => %{},
          "body" => ""
        })

      result = HttpHandler.execute(request, edge, limits, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "domain_blocked"
    end

    test "blocks request with disallowed method", %{
      edge: edge,
      limits: limits,
      ctx: ctx,
      component_ref: ref
    } do
      request =
        Jason.encode!(%{
          "method" => "DELETE",
          "url" => "https://api.stripe.com/v1/charges",
          "headers" => %{},
          "body" => ""
        })

      result = HttpHandler.execute(request, edge, limits, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "method_blocked"
    end

    test "blocks request with oversized body", %{
      edge: edge,
      limits: limits,
      ctx: ctx,
      component_ref: ref
    } do
      large_body = String.duplicate("x", 2048)

      request =
        Jason.encode!(%{
          "method" => "POST",
          "url" => "https://api.stripe.com/v1/charges",
          "headers" => %{},
          "body" => large_body
        })

      result = HttpHandler.execute(request, edge, limits, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "request_too_large"
      assert decoded["error"]["message"] =~ "exceeds limit"
    end

    test "returns error for invalid JSON request", %{
      edge: edge,
      limits: limits,
      ctx: ctx,
      component_ref: ref
    } do
      result = HttpHandler.execute("not-json", edge, limits, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "http_error"
      assert decoded["error"]["message"] =~ "Invalid JSON"
    end

    test "returns error for request missing required fields", %{
      edge: edge,
      limits: limits,
      ctx: ctx,
      component_ref: ref
    } do
      request = Jason.encode!(%{"url" => "https://api.stripe.com"})
      result = HttpHandler.execute(request, edge, limits, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "http_error"
      assert decoded["error"]["message"] =~ "must include"
    end

    test "returns error for request with invalid URL", %{
      edge: edge,
      limits: limits,
      ctx: ctx,
      component_ref: ref
    } do
      request = Jason.encode!(%{"method" => "GET", "url" => "not-a-url"})
      result = HttpHandler.execute(request, edge, limits, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "http_error"
      assert decoded["error"]["message"] =~ "missing hostname"
    end

    test "blocks request to private IP (localhost)", %{
      limits: limits,
      ctx: ctx,
      component_ref: ref
    } do
      # Use localhost in allowed domains so we get past the domain check
      edge = EdgeFixtures.edge(domains: ["localhost"], methods: ["GET", "POST"])

      request =
        Jason.encode!(%{
          "method" => "GET",
          "url" => "http://localhost/admin",
          "headers" => %{},
          "body" => ""
        })

      result = HttpHandler.execute(request, edge, limits, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "private_ip_blocked"
      assert decoded["error"]["message"] =~ "127.0.0.1"
    end
  end

  # ============================================================================
  # build_http_imports/4
  # ============================================================================

  describe "build_http_imports/4" do
    test "returns correct Wasmex import shape" do
      edge = EdgeFixtures.edge()
      limits = EdgeFixtures.limits()
      ctx = Sanctum.TestContext.local()

      imports = HttpHandler.build_http_imports(edge, limits, ctx, "local.test-component:1.0.0")

      assert is_map(imports)
      assert Map.has_key?(imports, "cyfr:http/fetch@0.1.0")

      fetch_ns = imports["cyfr:http/fetch@0.1.0"]
      assert Map.has_key?(fetch_ns, "request")

      {:fn, func} = fetch_ns["request"]
      assert is_function(func, 1)
    end

    test "returned function is callable and returns JSON" do
      edge = EdgeFixtures.edge(domains: ["blocked-only.test"], methods: ["GET"])
      limits = EdgeFixtures.limits()

      ctx = Sanctum.TestContext.local()
      imports = HttpHandler.build_http_imports(edge, limits, ctx, "local.test-component:1.0.0")

      {:fn, func} = imports["cyfr:http/fetch@0.1.0"]["request"]

      # Call with a blocked domain to verify it works end-to-end
      request =
        Jason.encode!(%{
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
  # execute/5 - base64 body encoding
  # ============================================================================

  describe "execute/5 base64 body encoding" do
    setup do
      case GenServer.whereis(Opus.RateLimiter) do
        nil -> {:ok, _} = Opus.RateLimiter.start_link([])
        _pid -> :ok
      end

      edge = EdgeFixtures.edge(domains: ["api.openai.com"], methods: ["POST"])

      limits = EdgeFixtures.limits(max_request_size: 1024, max_response_size: 4096)

      ctx = Sanctum.TestContext.local()
      component_ref = "local.test-catalyst-b64:1.0.0"

      {:ok, edge: edge, limits: limits, ctx: ctx, component_ref: component_ref}
    end

    test "rejects invalid base64 body", %{
      edge: edge,
      limits: limits,
      ctx: ctx,
      component_ref: ref
    } do
      request =
        Jason.encode!(%{
          "method" => "POST",
          "url" => "https://api.openai.com/v1/audio/speech",
          "headers" => %{},
          "body" => "not-valid-base64!!!",
          "body_encoding" => "base64"
        })

      result = HttpHandler.execute(request, edge, limits, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "http_error"
      assert decoded["error"]["message"] =~ "Invalid base64"
    end

    test "validates decoded body size against the node limit", %{
      edge: edge,
      limits: limits,
      ctx: ctx,
      component_ref: ref
    } do
      # Create base64 content that decodes to > 1024 bytes
      large_binary = String.duplicate("x", 2048)
      encoded = Base.encode64(large_binary)

      request =
        Jason.encode!(%{
          "method" => "POST",
          "url" => "https://api.openai.com/v1/audio/speech",
          "headers" => %{},
          "body" => encoded,
          "body_encoding" => "base64"
        })

      result = HttpHandler.execute(request, edge, limits, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "request_too_large"
    end
  end

  # ============================================================================
  # execute/5 - multipart support
  # ============================================================================

  describe "execute/5 multipart" do
    setup do
      case GenServer.whereis(Opus.RateLimiter) do
        nil -> {:ok, _} = Opus.RateLimiter.start_link([])
        _pid -> :ok
      end

      edge = EdgeFixtures.edge(domains: ["api.openai.com"], methods: ["POST"])

      limits = EdgeFixtures.limits(max_request_size: 1024, max_response_size: 4096)

      ctx = Sanctum.TestContext.local()
      component_ref = "local.test-catalyst-mp:1.0.0"

      {:ok, edge: edge, limits: limits, ctx: ctx, component_ref: component_ref}
    end

    test "rejects request with both body and multipart", %{
      edge: edge,
      limits: limits,
      ctx: ctx,
      component_ref: ref
    } do
      request =
        Jason.encode!(%{
          "method" => "POST",
          "url" => "https://api.openai.com/v1/audio/transcriptions",
          "headers" => %{},
          "body" => "some body",
          "multipart" => [
            %{"name" => "model", "value" => "whisper-1"}
          ]
        })

      result = HttpHandler.execute(request, edge, limits, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "http_error"
      assert decoded["error"]["message"] =~ "both 'body' and 'multipart'"
    end

    test "rejects multipart with invalid base64 data", %{
      edge: edge,
      limits: limits,
      ctx: ctx,
      component_ref: ref
    } do
      request =
        Jason.encode!(%{
          "method" => "POST",
          "url" => "https://api.openai.com/v1/audio/transcriptions",
          "headers" => %{},
          "multipart" => [
            %{
              "name" => "file",
              "filename" => "audio.mp3",
              "content_type" => "audio/mpeg",
              "data" => "not-valid!!!"
            },
            %{"name" => "model", "value" => "whisper-1"}
          ]
        })

      result = HttpHandler.execute(request, edge, limits, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "http_error"
      assert decoded["error"]["message"] =~ "Invalid base64"
    end

    test "validates multipart total decoded size against the node limit", %{
      edge: edge,
      limits: limits,
      ctx: ctx,
      component_ref: ref
    } do
      # Create file content that exceeds 1024 byte limit
      large_file = String.duplicate("x", 2048)
      encoded = Base.encode64(large_file)

      request =
        Jason.encode!(%{
          "method" => "POST",
          "url" => "https://api.openai.com/v1/audio/transcriptions",
          "headers" => %{},
          "multipart" => [
            %{
              "name" => "file",
              "filename" => "audio.mp3",
              "content_type" => "audio/mpeg",
              "data" => encoded
            },
            %{"name" => "model", "value" => "whisper-1"}
          ]
        })

      result = HttpHandler.execute(request, edge, limits, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "request_too_large"
      assert decoded["error"]["message"] =~ "Multipart body"
    end

    test "rejects multipart part without name", %{
      edge: edge,
      limits: limits,
      ctx: ctx,
      component_ref: ref
    } do
      request =
        Jason.encode!(%{
          "method" => "POST",
          "url" => "https://api.openai.com/v1/audio/transcriptions",
          "headers" => %{},
          "multipart" => [
            %{"value" => "whisper-1"}
          ]
        })

      result = HttpHandler.execute(request, edge, limits, ctx, ref)
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
      result =
        HttpHandler.encode_response_base64(
          200,
          [{"content-type", "audio/mpeg"}],
          "binary audio data"
        )

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

  # ============================================================================
  # SSRF Edge Cases — IPv4-mapped IPv6 and boundary conditions
  # ============================================================================

  describe "private_ip?/1 SSRF edge cases" do
    # IPv4-mapped IPv6 addresses (::ffff:x.x.x.x)
    # These are a common SSRF bypass vector where an attacker uses
    # IPv6 notation to represent a private IPv4 address.

    test "blocks IPv4-mapped IPv6 loopback ::ffff:127.0.0.1" do
      assert HttpHandler.private_ip?({0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001})
    end

    test "blocks IPv4-mapped IPv6 metadata endpoint ::ffff:169.254.169.254" do
      # AWS metadata endpoint: 169.254.169.254 = {0xA9FE, 0xA9FE}
      assert HttpHandler.private_ip?({0, 0, 0, 0, 0, 0xFFFF, 0xA9FE, 0xA9FE})
    end

    test "blocks IPv4-mapped IPv6 private 192.168.1.1" do
      # 192.168.1.1 => high = (192 << 8) | 168 = 0xC0A8, low = (1 << 8) | 1 = 0x0101
      assert HttpHandler.private_ip?({0, 0, 0, 0, 0, 0xFFFF, 0xC0A8, 0x0101})
    end

    test "blocks IPv4-mapped IPv6 private 172.16.0.1" do
      # 172.16.0.1 => high = (172 << 8) | 16 = 0xAC10, low = (0 << 8) | 1 = 0x0001
      assert HttpHandler.private_ip?({0, 0, 0, 0, 0, 0xFFFF, 0xAC10, 0x0001})
    end

    test "allows IPv4-mapped IPv6 with public IP ::ffff:1.1.1.1" do
      # 1.1.1.1 => high = (1 << 8) | 1 = 0x0101, low = (1 << 8) | 1 = 0x0101
      refute HttpHandler.private_ip?({0, 0, 0, 0, 0, 0xFFFF, 0x0101, 0x0101})
    end

    test "allows IPv4-mapped IPv6 with public IP ::ffff:93.184.216.34" do
      # 93.184.216.34 => high = (93 << 8) | 184 = 0x5DB8, low = (216 << 8) | 34 = 0xD822
      refute HttpHandler.private_ip?({0, 0, 0, 0, 0, 0xFFFF, 0x5DB8, 0xD822})
    end

    # Boundary conditions for private ranges

    test "blocks 172.16.0.0 (start of /12 range)" do
      assert HttpHandler.private_ip?({172, 16, 0, 0})
    end

    test "blocks 172.31.255.255 (end of /12 range)" do
      assert HttpHandler.private_ip?({172, 31, 255, 255})
    end

    test "allows 172.32.0.0 (just outside /12 range)" do
      refute HttpHandler.private_ip?({172, 32, 0, 0})
    end

    test "blocks 0.0.0.0 (current network)" do
      assert HttpHandler.private_ip?({0, 0, 0, 0})
    end

    test "blocks 0.255.255.255 (end of 0.0.0.0/8)" do
      assert HttpHandler.private_ip?({0, 255, 255, 255})
    end

    test "allows 1.0.0.0 (just outside 0.0.0.0/8)" do
      refute HttpHandler.private_ip?({1, 0, 0, 0})
    end

    # IPv6 boundary edge cases

    test "blocks fc00::1 (start of unique local)" do
      assert HttpHandler.private_ip?({0xFC00, 0, 0, 0, 0, 0, 0, 1})
    end

    test "blocks fdff:ffff:... (end of unique local)" do
      assert HttpHandler.private_ip?(
               {0xFDFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF}
             )
    end

    test "allows fbff::1 (just before unique local range)" do
      refute HttpHandler.private_ip?({0xFBFF, 0, 0, 0, 0, 0, 0, 1})
    end

    test "allows fe00::1 (between unique-local and link-local)" do
      refute HttpHandler.private_ip?({0xFE00, 0, 0, 0, 0, 0, 0, 1})
    end

    test "blocks fe80::1 (start of link-local)" do
      assert HttpHandler.private_ip?({0xFE80, 0, 0, 0, 0, 0, 0, 1})
    end

    test "blocks febf:ffff:... (end of link-local)" do
      assert HttpHandler.private_ip?(
               {0xFEBF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF}
             )
    end

    test "allows fec0::1 (just after link-local range)" do
      refute HttpHandler.private_ip?({0xFEC0, 0, 0, 0, 0, 0, 0, 1})
    end
  end

  # ============================================================================
  # SSRF via URL parsing edge cases
  # ============================================================================

  describe "execute/5 SSRF URL edge cases" do
    setup do
      case GenServer.whereis(Opus.RateLimiter) do
        nil -> {:ok, _} = Opus.RateLimiter.start_link([])
        _pid -> :ok
      end

      # Edge that allows all domains (so we test IP-level blocking)
      edge = EdgeFixtures.edge(domains: ["*"], methods: ["GET"])

      limits = EdgeFixtures.limits(max_request_size: 1024, max_response_size: 4096)

      ctx = Sanctum.TestContext.local()
      component_ref = "local.ssrf-test:1.0.0"

      {:ok, edge: edge, limits: limits, ctx: ctx, component_ref: component_ref}
    end

    test "blocks numeric IP for private address", %{
      edge: edge,
      limits: limits,
      ctx: ctx,
      component_ref: ref
    } do
      request =
        Jason.encode!(%{
          "method" => "GET",
          "url" => "http://127.0.0.1/admin",
          "headers" => %{},
          "body" => ""
        })

      result = HttpHandler.execute(request, edge, limits, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "private_ip_blocked"
    end

    test "blocks 0.0.0.0 as direct IP", %{
      edge: edge,
      limits: limits,
      ctx: ctx,
      component_ref: ref
    } do
      request =
        Jason.encode!(%{
          "method" => "GET",
          "url" => "http://0.0.0.0/",
          "headers" => %{},
          "body" => ""
        })

      result = HttpHandler.execute(request, edge, limits, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "private_ip_blocked"
    end

    test "blocks metadata endpoint IP 169.254.169.254", %{
      edge: edge,
      limits: limits,
      ctx: ctx,
      component_ref: ref
    } do
      request =
        Jason.encode!(%{
          "method" => "GET",
          "url" => "http://169.254.169.254/latest/meta-data/",
          "headers" => %{},
          "body" => ""
        })

      result = HttpHandler.execute(request, edge, limits, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "private_ip_blocked"
    end

    test "blocks [::1] IPv6 loopback", %{edge: edge, limits: limits, ctx: ctx, component_ref: ref} do
      request =
        Jason.encode!(%{
          "method" => "GET",
          "url" => "http://[::1]/admin",
          "headers" => %{},
          "body" => ""
        })

      result = HttpHandler.execute(request, edge, limits, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "private_ip_blocked"
    end

    test "rejects URL with empty hostname", %{
      edge: edge,
      limits: limits,
      ctx: ctx,
      component_ref: ref
    } do
      request =
        Jason.encode!(%{
          "method" => "GET",
          "url" => "http:///path",
          "headers" => %{},
          "body" => ""
        })

      result = HttpHandler.execute(request, edge, limits, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "http_error"
    end
  end
end
