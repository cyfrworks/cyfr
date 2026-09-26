# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.HttpRequestValidationTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Opus.HttpRequestValidation
  alias Opus.Test.EdgeFixtures
  alias Opus.Test.ScriptedHost

  # A scripted host, the client of an attempt on it — which takes each
  # request from the attempt's rate through a `take_rate` host call and asks
  # for each request's address through an `egress_pin` one, pinned from the
  # host's table — and the component reference its bucket keys on.
  defp attached_host(pins \\ %{"localhost" => "127.0.0.1"}) do
    host = ScriptedHost.start!()
    ScriptedHost.pins(host, pins)
    attempt = ScriptedHost.attempt!(host)
    {host, attempt.client, attempt.component_ref}
  end

  # Every call goes through the full production entry with the host client a
  # real caller supplies; the scripted host admits every request to the rate.
  defp validate(json, edge, limits, opts \\ []) do
    {_host, client, ref} = attached_host()
    HttpRequestValidation.validate(json, edge, limits, client, ref, opts)
  end

  defp encode(overrides) do
    Map.merge(
      %{"method" => "GET", "url" => "http://localhost/x", "headers" => %{}, "body" => ""},
      overrides
    )
    |> Jason.encode!()
  end

  # An edge that lets validation reach the pin
  defp localhost_edge(opts \\ []) do
    EdgeFixtures.edge(Keyword.merge([domains: ["localhost"], methods: ["GET", "POST"]], opts))
  end

  describe "validate/6" do
    test "returns a validated request with the pinned address, the pin and the method atom" do
      {host, client, ref} = attached_host()

      assert {:ok, request} =
               HttpRequestValidation.validate(
                 encode(%{}),
                 localhost_edge(),
                 EdgeFixtures.limits(),
                 client,
                 ref
               )

      assert request.ip == "127.0.0.1"
      assert request.pin_req_opts[:url] == "http://127.0.0.1/x"
      assert request.pin_req_opts[:connect_options][:hostname] == "localhost"
      assert request.pinned.target.host == "localhost"
      assert request.method_atom == :get
      assert request.method == "GET"
      assert request.hostname == "localhost"

      assert [%{args: %{"url" => "http://localhost/x", "purpose" => "fetch"}}] =
               ScriptedHost.requests(host, "egress_pin")
    end

    test "a stream's request is pinned for a stream" do
      {host, client, ref} = attached_host()

      assert {:ok, _request} =
               HttpRequestValidation.validate(
                 encode(%{}),
                 localhost_edge(),
                 EdgeFixtures.limits(),
                 client,
                 ref,
                 purpose: :stream
               )

      assert [%{args: %{"purpose" => "stream"}}] = ScriptedHost.requests(host, "egress_pin")
    end

    test "the engine sends to exactly the address the host pins, which decides private ones" do
      # The consented private-address policy is the host's: the engine
      # connects to the private address the host pinned, and to nothing
      # it resolved itself.
      {_host, client, ref} = attached_host(%{"localhost" => "10.0.0.5"})

      assert {:ok, request} =
               HttpRequestValidation.validate(
                 encode(%{}),
                 localhost_edge(),
                 EdgeFixtures.limits(),
                 client,
                 ref
               )

      assert request.ip == "10.0.0.5"
      assert request.pin_req_opts[:url] == "http://10.0.0.5/x"
    end

    test "rejects invalid JSON" do
      assert {:error, :invalid_json, "Invalid JSON request"} =
               validate("not-json", localhost_edge(), EdgeFixtures.limits())
    end

    test "rejects request missing method/url" do
      assert {:error, :invalid_request, "Invalid request: must include 'method' and 'url'"} =
               validate(
                 Jason.encode!(%{"url" => "http://localhost/x"}),
                 localhost_edge(),
                 EdgeFixtures.limits()
               )
    end

    test "rejects URL without hostname" do
      assert {:error, :invalid_request, "Invalid URL: missing hostname"} =
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

    test "request size is enforced before the address is pinned" do
      edge = EdgeFixtures.edge(domains: ["*"], methods: ["POST"])
      limits = EdgeFixtures.limits(max_request_size: 16)
      {host, client, ref} = attached_host()

      request =
        encode(%{
          "method" => "POST",
          "url" => "https://this-domain-does-not-exist-cyfr-test.invalid/x",
          "body" => String.duplicate("x", 100)
        })

      assert {:error, :request_too_large, msg} =
               HttpRequestValidation.validate(request, edge, limits, client, ref)

      assert ScriptedHost.requests(host, "egress_pin") == []

      # 100 body bytes plus the URL: the ceiling counts what the host holds
      # and puts on the wire, not the body alone.
      assert msg =~ ~r/^Request \(\d+ bytes incl\. URL and headers\) exceeds limit \(16 bytes\)$/
    end

    test "headers count toward max_request_size, not just the body" do
      # Measuring the body alone let a guest move megabytes through header
      # values — into host memory and out to the upstream — while the
      # consented ceiling read as enforced.
      edge = EdgeFixtures.edge(domains: ["*"], methods: ["POST"])
      limits = EdgeFixtures.limits(max_request_size: 512)

      request =
        encode(%{
          "method" => "POST",
          "url" => "https://example.com/x",
          "body" => "",
          "headers" => %{"x-padding" => String.duplicate("h", 4096)}
        })

      assert {:error, :request_too_large, msg} = validate(request, edge, limits)
      assert msg =~ "exceeds limit (512 bytes)"
    end

    test "an oversized envelope is refused before it is parsed" do
      # The decoded-payload ceiling cannot bound what it costs to produce the
      # decoded payload; only the guest's 64 MiB linear memory did.
      edge = EdgeFixtures.edge(domains: ["*"], methods: ["POST"])
      limits = EdgeFixtures.limits(max_request_size: 16)

      # Well past `max_request_size * 2 + envelope_overhead`, and deliberately
      # not valid JSON — a parse error would prove the bound ran too late.
      assert {:error, :request_too_large, msg} =
               validate(String.duplicate("{", 32_768), edge, limits)

      assert msg =~ "consented max_request_size"
    end

    test "an address the host refuses is its refusal, which the host has recorded" do
      edge = EdgeFixtures.edge(domains: ["localhost"], methods: ["GET"])
      {_host, client, ref} = attached_host(%{"localhost" => :denied})

      assert {:refused, :private_ip_blocked, msg} =
               HttpRequestValidation.validate(
                 encode(%{}),
                 edge,
                 EdgeFixtures.limits(),
                 client,
                 ref
               )

      assert msg =~ "localhost"
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

      assert {:error, :invalid_request, "Streaming requests do not support 'multipart'"} =
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
    test "the rate is taken from CYFR, per component, before the pin, and its refusal denies the request" do
      {host, client, ref} = attached_host()
      limits = EdgeFixtures.limits()

      ScriptedHost.script(host, "take_rate", [
        {:ok, true},
        {:error, {:guest_error, "rate_limited", "Rate limit exceeded for http:" <> ref}}
      ])

      assert {:ok, _} =
               HttpRequestValidation.validate(encode(%{}), localhost_edge(), limits, client, ref)

      assert {:error, :rate_limited, message} =
               HttpRequestValidation.validate(encode(%{}), localhost_edge(), limits, client, ref)

      assert message =~ "Rate limit"

      assert [%{args: %{"bucket" => bucket}}, %{args: %{"bucket" => bucket}}] =
               ScriptedHost.requests(host, "take_rate")

      assert bucket == "http:" <> ref

      # The refused request asked for no address: only the admitted one did.
      assert length(ScriptedHost.requests(host, "egress_pin")) == 1
    end

    test "the rate is the attempt's: the limits the runner passes grant nothing" do
      {host, client, ref} = attached_host()
      ScriptedHost.script(host, "take_rate", {:error, {:guest_error, "rate_limited", "denied"}})
      wide = EdgeFixtures.limits(rate_limit: %{requests: 1000, window: "1m"})

      assert {:error, :rate_limited, "denied"} =
               HttpRequestValidation.validate(encode(%{}), localhost_edge(), wide, client, ref)
    end

    test "a request is refused once its attempt is no longer current, or the answer is lost" do
      {host, client, ref} = attached_host()
      ScriptedHost.script(host, "take_rate", [{:error, :lost}, {:error, :unavailable}, :drop])
      limits = EdgeFixtures.limits()

      assert {:error, :rate_limited, message} =
               HttpRequestValidation.validate(encode(%{}), localhost_edge(), limits, client, ref)

      assert message =~ "not current"

      assert {:error, :rate_limited, "HTTP egress refused: rate limiter unavailable"} =
               HttpRequestValidation.validate(encode(%{}), localhost_edge(), limits, client, ref)

      assert {:error, :rate_limited, message} =
               HttpRequestValidation.validate(encode(%{}), localhost_edge(), limits, client, ref)

      assert message =~ "lost"
    end
  end
end
