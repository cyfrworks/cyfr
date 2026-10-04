# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.HttpRequestValidationTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Opus.HttpRequestValidation
  alias Opus.Test.EdgeFixtures
  alias Opus.Test.ScriptedHost
  alias Prima.AttachedRequest

  # A scripted host, the client of an attempt on it — which asks for each
  # request's address through an `egress_pin` host call, pinned from the
  # host's table — and the component reference.
  defp attached_host(pins \\ %{"localhost" => "127.0.0.1"}) do
    host = ScriptedHost.start!()
    ScriptedHost.pins(host, pins)
    attempt = ScriptedHost.attempt!(host)
    {host, attempt.client, attempt.component_ref}
  end

  # Every call goes through the full production entry with the host client a
  # real caller supplies.
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
      refute Map.has_key?(request, :pin_req_opts)
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
      assert request.pinned.target.ip == "10.0.0.5"
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

    test "a cross-origin hop goes without every header that carries a credential, in either shape" do
      # The header vector of tests/fixtures/host_api.json: what a hop to
      # another origin keeps of its request's headers.
      vector =
        Path.expand("../../../../tests/fixtures/host_api.json", __DIR__)
        |> File.read!()
        |> Jason.decode!()
        |> Map.fetch!("egress_policy_cases")
        |> Enum.find(&(&1["name"] == "redirect_strip_credentials"))

      pairs = fn pairs ->
        pairs |> Enum.map(fn [name, value] -> {name, value} end) |> Enum.sort()
      end

      before = pairs.(vector["headers_before"])

      # The headers as an object of names to values, and as the vector's
      # array of [name, value] pairs.
      for headers <- [Map.new(before), vector["headers_before"]] do
        {_host, client, ref} =
          attached_host(%{
            "api.example.test" => "203.0.113.10",
            "static.cdn.example.test" => "203.0.113.12"
          })

        edge =
          EdgeFixtures.edge(domains: ["api.example.test", "*.cdn.example.test"], methods: ["GET"])

        start = "https://api.example.test/v1/items"

        request = fn url ->
          json = encode(%{"url" => url, "headers" => headers})
          HttpRequestValidation.validate(json, edge, EdgeFixtures.limits(), client, ref)
        end

        assert {:ok, first} = request.(start)
        assert Enum.sort(first.headers) == before

        # A hop on the pin's origin keeps them all.
        same = "https://api.example.test:443/v1/items/3"
        :ok = Opus.Egress.redirected(client, first.pinned, start, same)
        assert {:ok, %{headers: kept}} = request.(same)
        assert Enum.sort(kept) == before

        # A hop to another origin keeps what the vector keeps, `X-API-Key`
        # and every `-token`, `-key` and `-secret` name dropped with it.
        other = "https://static.cdn.example.test/v1/items/4"
        :ok = Opus.Egress.redirected(client, first.pinned, start, other)
        assert {:ok, %{headers: stripped} = hop} = request.(other)
        assert Opus.Egress.cross_origin?(hop.pinned)
        assert Enum.sort(stripped) == pairs.(vector["headers_after"])
        refute Enum.any?(stripped, fn {name, _value} -> String.downcase(name) == "x-api-key" end)
      end
    end

    test "headers in an array are [name, value] pairs, read as the object's are" do
      assert {:ok, %{headers: [{"Accept", "a"}, {"X-Count", "2"}, {"accept", "b"}]}} =
               validate(
                 encode(%{"headers" => [["Accept", "a"], ["X-Count", 2], ["accept", "b"]]}),
                 localhost_edge(),
                 EdgeFixtures.limits()
               )

      for headers <- [
            [["Authorization"]],
            [["Authorization", "Bearer a", "extra"]],
            [%{"Authorization" => "Bearer a"}],
            ["Authorization: Bearer a"],
            [[1, "a"]],
            [["", "a"]],
            [["X-Nested", ["a"]]],
            %{"X-Nested" => %{"a" => "b"}}
          ] do
        assert {:error, :invalid_request, "Invalid headers: " <> _} =
                 validate(
                   encode(%{"headers" => headers}),
                   localhost_edge(),
                   EdgeFixtures.limits()
                 ),
               inspect(headers)
      end
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

  describe "a request naming a connection" do
    defp attached_request(overrides) do
      encode(
        Map.merge(%{"connection" => "api_key", "url" => "https://localhost/v1/x"}, overrides)
      )
    end

    test "asks for no pin and carries the request CYFR makes, read as CYFR reads it" do
      {host, client, ref} = attached_host()

      assert {:ok, request} =
               HttpRequestValidation.validate(
                 attached_request(%{
                   "method" => "POST",
                   "headers" => [["Content-Type", "application/json"], ["X-Trace", "t"]],
                   "body" => ~s({"a":1}),
                   "_webhook" => %{"event" => "ignored"}
                 }),
                 localhost_edge(),
                 EdgeFixtures.limits(),
                 client,
                 ref
               )

      assert %AttachedRequest{
               connection: "api_key",
               method: "POST",
               url: "https://localhost/v1/x",
               headers: [{"Content-Type", "application/json"}, {"X-Trace", "t"}],
               body: ~s({"a":1}),
               purpose: :fetch
             } = attached = request.attached

      assert AttachedRequest.valid_call_id?(attached.call_id)
      assert AttachedRequest.read(AttachedRequest.to_args(attached)) == {:ok, attached}
      refute Map.has_key?(request, :pinned)
      assert ScriptedHost.requests(host) == []

      # Each request has a call id of its own.
      assert {:ok, again} =
               HttpRequestValidation.validate(
                 attached_request(%{}),
                 localhost_edge(),
                 EdgeFixtures.limits(),
                 client,
                 ref
               )

      assert again.attached.call_id != attached.call_id
    end

    test "a stream's request is made for a stream" do
      assert {:ok, %{attached: %AttachedRequest{purpose: :stream}}} =
               validate(attached_request(%{}), localhost_edge(), EdgeFixtures.limits(),
                 purpose: :stream,
                 allow_multipart: false
               )
    end

    test "the runner's own checks run first: the envelope, the edge and the size" do
      limits = EdgeFixtures.limits(max_request_size: 64)

      assert {:error, :request_too_large, _} =
               validate(String.duplicate("{", 32_768), localhost_edge(), limits)

      assert {:error, :domain_blocked, _} =
               validate(
                 attached_request(%{"url" => "https://elsewhere.test/x"}),
                 localhost_edge(),
                 limits
               )

      assert {:error, :method_blocked, _} =
               validate(attached_request(%{"method" => "DELETE"}), localhost_edge(), limits)

      assert {:error, :scheme_blocked, _} =
               validate(attached_request(%{}), localhost_edge(schemes: ["http"]), limits)

      assert {:error, :request_too_large, _} =
               validate(
                 attached_request(%{"method" => "POST", "body" => String.duplicate("b", 100)}),
                 localhost_edge(),
                 limits
               )
    end

    test "a credential header is refused by shape, in any case, and a header CYFR sets by name" do
      for name <- ["Authorization", "authorization", "X-API-KEY", "Cookie", "Proxy-Authorization"] do
        assert {:error, :credential_header_refused, message} =
                 validate(
                   attached_request(%{"headers" => %{name => "Bearer guest"}}),
                   localhost_edge(),
                   EdgeFixtures.limits()
                 ),
               name

        assert message == Prima.Refusal.message(:credential_header_refused)
      end

      for name <- ["Host", "Transfer-Encoding", "X-Forwarded-Host"] do
        assert {:error, :invalid_request, message} =
                 validate(
                   attached_request(%{"headers" => %{name => "x"}}),
                   localhost_edge(),
                   EdgeFixtures.limits()
                 ),
               name

        assert message =~ name
      end

      # A pinned request with the same header is the guest's own to send.
      assert {:ok, %{pinned: _}} =
               validate(
                 encode(%{"headers" => %{"Authorization" => "Bearer guest"}}),
                 localhost_edge(),
                 EdgeFixtures.limits()
               )
    end

    test "a connection that is not a string, or names no need, is refused" do
      assert {:error, :invalid_request, "Invalid connection: " <> _} =
               validate(
                 attached_request(%{"connection" => 7}),
                 localhost_edge(),
                 EdgeFixtures.limits()
               )

      for connection <- ["API KEY", "", "1key", String.duplicate("a", 40)] do
        assert {:error, :invalid_request, "The attached request does not read."} =
                 validate(
                   attached_request(%{"connection" => connection}),
                   localhost_edge(),
                   EdgeFixtures.limits()
                 ),
               connection
      end
    end

    test "a base64 body is sent decoded, and a multipart body encoded as a fetch sends it" do
      assert {:ok, %{attached: %{body: "raw bytes"}}} =
               validate(
                 attached_request(%{
                   "method" => "POST",
                   "body" => Base.encode64("raw bytes"),
                   "body_encoding" => "base64"
                 }),
                 localhost_edge(),
                 EdgeFixtures.limits()
               )

      assert {:ok, %{attached: %{headers: headers, body: body}}} =
               validate(
                 attached_request(%{
                   "method" => "POST",
                   "multipart" => [
                     %{"name" => "model", "value" => "whisper-1"},
                     %{"name" => "file", "filename" => "a.txt", "data" => Base.encode64("abc")}
                   ]
                 }),
                 localhost_edge(),
                 EdgeFixtures.limits()
               )

      assert [{"content-type", "multipart/form-data; boundary=" <> boundary}] = headers
      assert body =~ ~s(name="model"\r\n\r\nwhisper-1)
      assert body =~ ~s(filename="a.txt")
      assert String.ends_with?(body, "--" <> boundary <> "--\r\n")
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
    # The rate is the relay's service end's to take (`Opus.Relay`), before
    # it connects: a runner's own `take_rate` is refused there.
    test "the runner takes no rate itself: it pins, and the relay takes the rate" do
      {host, client, ref} = attached_host()
      ScriptedHost.script(host, "take_rate", {:error, {:guest_error, "rate_limited", "denied"}})

      assert {:ok, _request} =
               HttpRequestValidation.validate(
                 encode(%{}),
                 localhost_edge(),
                 EdgeFixtures.limits(),
                 client,
                 ref
               )

      assert ScriptedHost.requests(host, "take_rate") == []
      assert length(ScriptedHost.requests(host, "egress_pin")) == 1
    end
  end
end
