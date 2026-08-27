# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.HttpRequestValidationTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Opus.HttpRequestValidation
  alias Opus.Test.EdgeFixtures

  # Every call goes through the full production entry with the rate-limit
  # principals a real caller supplies; the default fixture's 100/1m budget
  # never trips in a test's handful of calls.
  defp validate(json, edge, limits, opts \\ []) do
    HttpRequestValidation.validate(
      json,
      edge,
      limits,
      Sanctum.TestContext.local(),
      "test:probe",
      opts
    )
  end

  defp encode(overrides) do
    Map.merge(
      %{"method" => "GET", "url" => "http://localhost/x", "headers" => %{}, "body" => ""},
      overrides
    )
    |> Jason.encode!()
  end

  # An edge that lets validation reach DNS resolution without leaving the host
  defp localhost_edge(opts \\ []) do
    EdgeFixtures.edge(
      Keyword.merge(
        [domains: ["localhost"], methods: ["GET", "POST"], private_ips: ["127.0.0.1"]],
        opts
      )
    )
  end

  describe "validate/6" do
    test "returns a validated request with pinned IP and method atom" do
      assert {:ok, request} =
               validate(
                 encode(%{}),
                 localhost_edge(),
                 EdgeFixtures.limits()
               )

      assert request.ip == "127.0.0.1"
      assert request.method_atom == :get
      assert request.method == "GET"
      assert request.hostname == "localhost"
    end

    test "rejects invalid JSON" do
      assert {:error, :http_error, "Invalid JSON request"} =
               validate("not-json", localhost_edge(), EdgeFixtures.limits())
    end

    test "rejects request missing method/url" do
      assert {:error, :http_error, "Invalid request: must include 'method' and 'url'"} =
               validate(
                 Jason.encode!(%{"url" => "http://localhost/x"}),
                 localhost_edge(),
                 EdgeFixtures.limits()
               )
    end

    test "rejects URL without hostname" do
      assert {:error, :http_error, "Invalid URL: missing hostname"} =
               validate(
                 encode(%{"url" => "http:///path"}),
                 localhost_edge(),
                 EdgeFixtures.limits()
               )
    end

    test "method allowlist is checked before the domain" do
      edge = EdgeFixtures.edge(domains: ["api.example.com"], methods: ["GET"])

      assert {:error, :method_blocked, _msg} =
               validate(
                 encode(%{"method" => "DELETE", "url" => "https://evil.example.net/x"}),
                 edge,
                 EdgeFixtures.limits()
               )
    end

    test "request size is enforced before DNS resolution" do
      edge = EdgeFixtures.edge(domains: ["*"], methods: ["POST"])
      limits = EdgeFixtures.limits(max_request_size: 16)

      request =
        encode(%{
          "method" => "POST",
          "url" => "https://this-domain-does-not-exist-cyfr-test.invalid/x",
          "body" => String.duplicate("x", 100)
        })

      assert {:error, :request_too_large, msg} =
               validate(request, edge, limits)

      assert msg == "Request body (100 bytes) exceeds limit (16 bytes)"
    end

    test "blocks private IPs through the shared resolve path" do
      edge = EdgeFixtures.edge(domains: ["localhost"], methods: ["GET"])

      assert {:error, :private_ip_blocked, msg} =
               validate(encode(%{}), edge, EdgeFixtures.limits())

      assert msg =~ "127.0.0.1"
    end

    test "rejects an edge-allowed but unsupported HTTP verb as method_blocked" do
      edge = localhost_edge(methods: ["TRACE"])

      assert {:error, :method_blocked, "Unsupported HTTP method: TRACE"} =
               validate(
                 encode(%{"method" => "TRACE"}),
                 edge,
                 EdgeFixtures.limits()
               )
    end

    test "allows multipart by default" do
      request =
        encode(%{
          "method" => "POST",
          "body" => "",
          "multipart" => [%{"name" => "model", "value" => "whisper-1"}]
        })

      assert {:ok, validated} =
               validate(request, localhost_edge(), EdgeFixtures.limits())

      assert [%{name: "model", value: "whisper-1"}] = validated.multipart
    end

    test "rejects multipart when allow_multipart: false" do
      request =
        encode(%{
          "method" => "POST",
          "body" => "",
          "multipart" => [%{"name" => "model", "value" => "whisper-1"}]
        })

      assert {:error, :http_error, "Streaming requests do not support 'multipart'"} =
               validate(
                 request,
                 localhost_edge(),
                 EdgeFixtures.limits(),
                 allow_multipart: false
               )
    end

    test "base64 body is decoded before the size check" do
      limits = EdgeFixtures.limits(max_request_size: 16)

      request =
        encode(%{
          "method" => "POST",
          "body" => Base.encode64(String.duplicate("x", 100)),
          "body_encoding" => "base64"
        })

      assert {:error, :request_too_large, _msg} =
               validate(request, localhost_edge(), limits)
    end
  end

  describe "timeout_ms/2" do
    test "derives the timeout from the node limits" do
      assert HttpRequestValidation.timeout_ms(EdgeFixtures.limits(timeout: "30s"), 60_000) ==
               30_000

      assert HttpRequestValidation.timeout_ms(EdgeFixtures.limits(timeout: "2m"), 60_000) ==
               120_000
    end

    test "falls back only when the limits carry an unparseable duration" do
      limits = %{EdgeFixtures.limits() | timeout: "bogus"}

      capture_log(fn ->
        assert HttpRequestValidation.timeout_ms(limits, 60_000) == 60_000
      end)
    end
  end
  describe "egress rate limiting" do
    test "the consented rate limit denies the wire-bound path itself" do
      ctx = Sanctum.TestContext.local()
      ref = "test:egress-#{System.unique_integer([:positive])}"
      limits = EdgeFixtures.limits(rate_limit: %{requests: 1, window: "1m"})

      assert {:ok, _} =
               HttpRequestValidation.validate(encode(%{}), localhost_edge(), limits, ctx, ref)

      assert {:error, :rate_limited, message} =
               HttpRequestValidation.validate(encode(%{}), localhost_edge(), limits, ctx, ref)

      assert message =~ "rate limit"
    end
  end
end
