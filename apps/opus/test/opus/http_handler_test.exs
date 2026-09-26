# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.HttpHandlerTest do
  use ExUnit.Case, async: true

  # Every address a request here connects to is the one the scripted host
  # pins it at, from the table each test sets: the engine resolves no name.

  alias Opus.HttpHandler
  alias Opus.Test.EdgeFixtures
  alias Opus.Test.ScriptedHost

  defmodule Upstream do
    @moduledoc false
    # A loopback upstream that records each request it is sent and
    # redirects `/redirect?to=<location>` to its `to`.
    @behaviour Plug

    import Plug.Conn

    @impl true
    def init(agent), do: agent

    @impl true
    def call(conn, agent) do
      conn = fetch_query_params(conn)

      Agent.update(
        agent,
        &(&1 ++ [%{path: conn.request_path, host: conn.host, headers: conn.req_headers}])
      )

      case conn.request_path do
        "/redirect" ->
          conn |> put_resp_header("location", conn.query_params["to"]) |> send_resp(302, "")

        _ ->
          send_resp(conn, 200, "reached " <> conn.request_path)
      end
    end
  end

  # The host client of an attempt on a scripted host for `component_ref`,
  # which takes every request from the rate, pins every address from
  # `pins` and records every refusal.
  defp attached_host(component_ref, _limits, pins \\ %{}) do
    host = ScriptedHost.start!()
    ScriptedHost.pins(host, pins)
    ScriptedHost.attempt!(host, component_ref: component_ref).client
  end

  # A scripted host pinning from `pins`, the client of an attempt on it,
  # and a loopback upstream with the requests it saw.
  defp upstream_and_host(pins) do
    agent = start_supervised!({Agent, fn -> [] end})

    server =
      start_supervised!(
        {Bandit, plug: {Upstream, agent}, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    host = ScriptedHost.start!()
    test = self()

    # Each pin the host answers is reported to the test, so a hop can be
    # matched to the pin its redirect came from.
    ScriptedHost.script(host, "egress_pin", fn args, _caller ->
      answer = ScriptedHost.pin(pins, args, 30_000)
      send(test, {:pinned, args, answer})
      answer
    end)

    attempt = ScriptedHost.attempt!(host, component_ref: "catalyst:local.redirects:1.0.0")
    %{host: host, client: attempt.client, port: port, seen: fn -> Agent.get(agent, & &1) end}
  end

  defp fetch(context, edge, url, headers \\ %{}) do
    %{"method" => "GET", "url" => url, "headers" => headers, "body" => ""}
    |> Jason.encode!()
    |> HttpHandler.execute(edge, EdgeFixtures.limits(), context.client, "catalyst:local.x:1.0.0")
    |> Jason.decode!()
  end

  # ============================================================================
  # execute/5 - edge enforcement
  # ============================================================================

  describe "execute/5 edge enforcement" do
    setup do
      edge =
        EdgeFixtures.edge(domains: ["api.stripe.com", "*.example.com"], methods: ["GET", "POST"])

      limits = EdgeFixtures.limits(max_request_size: 1024, max_response_size: 4096)

      component_ref = "catalyst:local.test-catalyst:1.0.0"

      {:ok,
       edge: edge,
       limits: limits,
       host: attached_host(component_ref, limits),
       component_ref: component_ref}
    end

    test "blocks request to non-allowed domain", %{
      edge: edge,
      limits: limits,
      host: host,
      component_ref: ref
    } do
      request =
        Jason.encode!(%{
          "method" => "GET",
          "url" => "https://evil.com/steal-data",
          "headers" => %{},
          "body" => ""
        })

      result = HttpHandler.execute(request, edge, limits, host, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "domain_blocked"
    end

    test "blocks request with disallowed method", %{
      edge: edge,
      limits: limits,
      host: host,
      component_ref: ref
    } do
      request =
        Jason.encode!(%{
          "method" => "DELETE",
          "url" => "https://api.stripe.com/v1/charges",
          "headers" => %{},
          "body" => ""
        })

      result = HttpHandler.execute(request, edge, limits, host, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "method_blocked"
    end

    # The guest writes this JSON, so its field types are not to be trusted.
    # A non-string method or url reached String.upcase/1 and URI.parse/1
    # unguarded; the raise killed the Wasmex process and with it the whole
    # execution, instead of handing the guest an error it could act on.
    for {label, request} <- [
          {"a numeric method", %{"method" => 1, "url" => "https://api.stripe.com/v1/charges"}},
          {"a numeric url", %{"method" => "GET", "url" => 2}},
          {"an object url", %{"method" => "GET", "url" => %{"href" => "https://x.test"}}},
          {"a null method", %{"method" => nil, "url" => "https://api.stripe.com/v1/charges"}}
        ] do
      test "#{label} is a typed error, never a raise", %{
        edge: edge,
        limits: limits,
        host: host,
        component_ref: ref
      } do
        json =
          Jason.encode!(
            Map.merge(%{"headers" => %{}, "body" => ""}, unquote(Macro.escape(request)))
          )

        result = HttpHandler.execute(json, edge, limits, host, ref)
        decoded = Jason.decode!(result)

        assert is_binary(decoded["error"]["type"])
        assert is_binary(decoded["error"]["message"])
      end
    end

    test "blocks request with oversized body", %{
      edge: edge,
      limits: limits,
      host: host,
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

      result = HttpHandler.execute(request, edge, limits, host, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "request_too_large"
      assert decoded["error"]["message"] =~ "exceeds limit"
    end

    test "returns error for invalid JSON request", %{
      edge: edge,
      limits: limits,
      host: host,
      component_ref: ref
    } do
      result = HttpHandler.execute("not-json", edge, limits, host, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "invalid_json"
      assert decoded["error"]["message"] =~ "Invalid JSON"
    end

    test "returns error for request missing required fields", %{
      edge: edge,
      limits: limits,
      host: host,
      component_ref: ref
    } do
      request = Jason.encode!(%{"url" => "https://api.stripe.com"})
      result = HttpHandler.execute(request, edge, limits, host, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "invalid_request"
      assert decoded["error"]["message"] =~ "must include"
    end

    test "returns error for request with invalid URL", %{
      edge: edge,
      limits: limits,
      host: host,
      component_ref: ref
    } do
      request = Jason.encode!(%{"method" => "GET", "url" => "not-a-url"})
      result = HttpHandler.execute(request, edge, limits, host, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "invalid_request"
      assert decoded["error"]["message"] =~ "missing hostname"
    end

    test "a private address the host refuses to pin is refused", %{
      limits: limits,
      component_ref: ref
    } do
      # Use localhost in allowed domains so we get past the domain check;
      # the private-address policy is the host's, which refuses it here.
      edge = EdgeFixtures.edge(domains: ["localhost"], methods: ["GET", "POST"])
      scripted = ScriptedHost.start!()
      ScriptedHost.pins(scripted, %{"localhost" => :denied})
      host = ScriptedHost.attempt!(scripted, component_ref: ref).client

      request =
        Jason.encode!(%{
          "method" => "GET",
          "url" => "http://localhost/admin",
          "headers" => %{},
          "body" => ""
        })

      result = HttpHandler.execute(request, edge, limits, host, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "private_ip_blocked"
      assert decoded["error"]["message"] =~ "localhost"

      # The host recorded its own refusal; the engine records none of it.
      assert ScriptedHost.requests(scripted, "record_denial") == []
    end
  end

  # ============================================================================
  # build_http_imports/4
  # ============================================================================

  describe "build_http_imports/4" do
    test "returns correct Wasmex import shape" do
      edge = EdgeFixtures.edge()
      limits = EdgeFixtures.limits()

      imports =
        HttpHandler.build_http_imports(
          edge,
          limits,
          attached_host("catalyst:local.test-component:1.0.0", limits),
          "catalyst:local.test-component:1.0.0"
        )

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

      imports =
        HttpHandler.build_http_imports(
          edge,
          limits,
          attached_host("catalyst:local.test-component:1.0.0", limits),
          "catalyst:local.test-component:1.0.0"
        )

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
      edge = EdgeFixtures.edge(domains: ["api.openai.com"], methods: ["POST"])

      limits = EdgeFixtures.limits(max_request_size: 1024, max_response_size: 4096)

      component_ref = "catalyst:local.test-catalyst-b64:1.0.0"

      {:ok,
       edge: edge,
       limits: limits,
       host: attached_host(component_ref, limits),
       component_ref: component_ref}
    end

    test "rejects invalid base64 body", %{
      edge: edge,
      limits: limits,
      host: host,
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

      result = HttpHandler.execute(request, edge, limits, host, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "invalid_request"
      assert decoded["error"]["message"] =~ "Invalid base64"
    end

    test "validates decoded body size against the node limit", %{
      edge: edge,
      limits: limits,
      host: host,
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

      result = HttpHandler.execute(request, edge, limits, host, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "request_too_large"
    end
  end

  # ============================================================================
  # execute/5 - multipart support
  # ============================================================================

  describe "execute/5 multipart" do
    setup do
      edge = EdgeFixtures.edge(domains: ["api.openai.com"], methods: ["POST"])

      limits = EdgeFixtures.limits(max_request_size: 1024, max_response_size: 4096)

      component_ref = "catalyst:local.test-catalyst-mp:1.0.0"

      {:ok,
       edge: edge,
       limits: limits,
       host: attached_host(component_ref, limits),
       component_ref: component_ref}
    end

    test "rejects request with both body and multipart", %{
      edge: edge,
      limits: limits,
      host: host,
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

      result = HttpHandler.execute(request, edge, limits, host, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "invalid_request"
      assert decoded["error"]["message"] =~ "both 'body' and 'multipart'"
    end

    test "rejects multipart with invalid base64 data", %{
      edge: edge,
      limits: limits,
      host: host,
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

      result = HttpHandler.execute(request, edge, limits, host, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "invalid_request"
      assert decoded["error"]["message"] =~ "Invalid base64"
    end

    test "validates multipart total decoded size against the node limit", %{
      edge: edge,
      limits: limits,
      host: host,
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

      result = HttpHandler.execute(request, edge, limits, host, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "request_too_large"
      assert decoded["error"]["message"] =~ "Multipart request"
    end

    test "rejects multipart part without name", %{
      edge: edge,
      limits: limits,
      host: host,
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

      result = HttpHandler.execute(request, edge, limits, host, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "invalid_request"
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
  # SSRF via URL parsing edge cases
  # ============================================================================

  describe "execute/5 SSRF URL edge cases" do
    setup do
      # Edge that allows all domains (so we test address-level blocking,
      # which is the host's: it refuses each of these to the pin)
      edge = EdgeFixtures.edge(domains: ["*"], methods: ["GET"])

      limits = EdgeFixtures.limits(max_request_size: 1024, max_response_size: 4096)

      component_ref = "catalyst:local.ssrf-test:1.0.0"

      pins = %{
        "127.0.0.1" => :denied,
        "0.0.0.0" => :denied,
        "::1" => :denied,
        "169.254.169.254" => :metadata
      }

      {:ok,
       edge: edge,
       limits: limits,
       host: attached_host(component_ref, limits, pins),
       component_ref: component_ref}
    end

    test "blocks numeric IP for private address", %{
      edge: edge,
      limits: limits,
      host: host,
      component_ref: ref
    } do
      request =
        Jason.encode!(%{
          "method" => "GET",
          "url" => "http://127.0.0.1/admin",
          "headers" => %{},
          "body" => ""
        })

      result = HttpHandler.execute(request, edge, limits, host, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "private_ip_blocked"
    end

    test "blocks 0.0.0.0 as direct IP", %{
      edge: edge,
      limits: limits,
      host: host,
      component_ref: ref
    } do
      request =
        Jason.encode!(%{
          "method" => "GET",
          "url" => "http://0.0.0.0/",
          "headers" => %{},
          "body" => ""
        })

      result = HttpHandler.execute(request, edge, limits, host, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "private_ip_blocked"
    end

    test "blocks metadata endpoint IP 169.254.169.254", %{
      edge: edge,
      limits: limits,
      host: host,
      component_ref: ref
    } do
      request =
        Jason.encode!(%{
          "method" => "GET",
          "url" => "http://169.254.169.254/latest/meta-data/",
          "headers" => %{},
          "body" => ""
        })

      result = HttpHandler.execute(request, edge, limits, host, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "private_ip_blocked"
      assert decoded["error"]["message"] =~ "metadata IP"
    end

    test "a metadata address the host pins is refused by the engine before any request", %{
      edge: edge,
      limits: limits,
      component_ref: ref
    } do
      scripted = ScriptedHost.start!()
      ScriptedHost.pins(scripted, %{"meta.example.com" => "169.254.169.254"})
      host = ScriptedHost.attempt!(scripted, component_ref: ref).client

      request = Jason.encode!(%{"method" => "GET", "url" => "http://meta.example.com/latest"})
      decoded = request |> HttpHandler.execute(edge, limits, host, ref) |> Jason.decode!()

      assert decoded["error"]["type"] == "private_ip_blocked"
      assert decoded["error"]["message"] =~ "metadata IP 169.254.169.254 blocked"

      # The engine's own refusal: the engine records it.
      assert [%{args: %{"type" => "private_ip_blocked"}}] =
               ScriptedHost.requests(scripted, "record_denial")
    end

    test "blocks [::1] IPv6 loopback", %{
      edge: edge,
      limits: limits,
      host: host,
      component_ref: ref
    } do
      request =
        Jason.encode!(%{
          "method" => "GET",
          "url" => "http://[::1]/admin",
          "headers" => %{},
          "body" => ""
        })

      result = HttpHandler.execute(request, edge, limits, host, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "private_ip_blocked"
    end

    test "rejects URL with empty hostname", %{
      edge: edge,
      limits: limits,
      host: host,
      component_ref: ref
    } do
      request =
        Jason.encode!(%{
          "method" => "GET",
          "url" => "http:///path",
          "headers" => %{},
          "body" => ""
        })

      result = HttpHandler.execute(request, edge, limits, host, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "invalid_request"
    end
  end

  # ============================================================================
  # The address a request connects to
  # ============================================================================

  describe "the address a request connects to" do
    test "is exactly the one the host pins, private or not, with the hostname kept" do
      # The private-address policy is the host's: the upstream is on the
      # loopback, which the host pins here, and the engine connects there.
      context = upstream_and_host(%{"api.test" => "127.0.0.1"})
      edge = EdgeFixtures.edge(domains: ["api.test"], methods: ["GET"])

      assert %{"status" => 200, "body" => "reached /hello"} =
               fetch(context, edge, "http://api.test:#{context.port}/hello")

      assert [%{path: "/hello", host: "api.test", headers: headers}] = context.seen.()
      assert {"host", "api.test:#{context.port}"} in headers
      assert_received {:pinned, %{"purpose" => "fetch"}, {:ok, %{"ip" => "127.0.0.1"}}}
    end

    test "is a plain literal for a family 4 pin and a bracketed one for family 6" do
      context =
        upstream_and_host(%{"v4.test" => "203.0.113.10", "v6.test" => "2001:db8::30"})

      edge = EdgeFixtures.edge(domains: ["v4.test", "v6.test"], methods: ["GET"])

      for {url, expected} <- [
            {"https://v4.test:8443/x", "https://203.0.113.10:8443/x"},
            {"https://v6.test:8443/x", "https://[2001:db8::30]:8443/x"}
          ] do
        request = Jason.encode!(%{"method" => "GET", "url" => url})

        assert {:ok, validated} =
                 Opus.HttpRequestValidation.validate(
                   request,
                   edge,
                   EdgeFixtures.limits(),
                   context.client,
                   "catalyst:local.x:1.0.0"
                 )

        assert validated.pin_req_opts[:url] == expected
        assert validated.pin_req_opts[:connect_options][:hostname] == URI.parse(url).host
      end
    end
  end

  # ============================================================================
  # A redirect the guest follows
  # ============================================================================

  describe "a redirect the guest follows" do
    setup do
      context =
        upstream_and_host(%{
          "api.test" => "127.0.0.1",
          "other.test" => "127.0.0.1",
          "login.other.test" => :redirect_credentials,
          "meta.other.test" => "169.254.169.254"
        })

      edge =
        EdgeFixtures.edge(domains: ["api.test", "other.test", "*.other.test"], methods: ["GET"])

      credentials = %{
        "Authorization" => "Bearer sk_test",
        "Cookie" => "session=1",
        "x-trace" => "t"
      }

      {:ok, context: context, edge: edge, credentials: credentials}
    end

    # The guest's first request, answered with a redirect to `to`, and the
    # pin it was made under.
    defp redirected(context, edge, credentials, to) do
      origin = "http://api.test:#{context.port}"

      assert %{"status" => 302, "headers" => %{"location" => ^to}} =
               fetch(
                 context,
                 edge,
                 origin <> "/redirect?to=" <> URI.encode_www_form(to),
                 credentials
               )

      assert_received {:pinned, %{"purpose" => "fetch"}, {:ok, %{"id" => pin}}}
      pin
    end

    test "a same-origin hop is pinned from the pin it came from and keeps the credentials", %{
      context: context,
      edge: edge,
      credentials: credentials
    } do
      pin = redirected(context, edge, credentials, "/landing")
      url = "http://api.test:#{context.port}/landing"

      assert %{"status" => 200} = fetch(context, edge, url, credentials)

      assert_received {:pinned, %{"purpose" => "redirect", "from" => ^pin, "url" => ^url},
                       {:ok, _}}

      assert [_redirect, %{path: "/landing", headers: headers}] = context.seen.()
      assert {"authorization", "Bearer sk_test"} in headers
      assert {"cookie", "session=1"} in headers
      assert {"x-trace", "t"} in headers
    end

    test "a cross-origin hop goes without the guest's Authorization and Cookie", %{
      context: context,
      edge: edge,
      credentials: credentials
    } do
      url = "http://other.test:#{context.port}/elsewhere"
      pin = redirected(context, edge, credentials, url)

      assert %{"status" => 200} = fetch(context, edge, url, credentials)
      assert_received {:pinned, %{"purpose" => "redirect", "from" => ^pin}, {:ok, _}}

      assert [_redirect, %{path: "/elsewhere", host: "other.test", headers: headers}] =
               context.seen.()

      refute List.keymember?(headers, "authorization", 0)
      refute List.keymember?(headers, "cookie", 0)
      assert {"x-trace", "t"} in headers

      # The hop was the redirect's alone: the next request there is the
      # guest's own, and carries what the guest sends.
      assert %{"status" => 200} = fetch(context, edge, url, credentials)
      assert %{headers: again} = List.last(context.seen.())
      assert {"authorization", "Bearer sk_test"} in again
    end

    test "the host's refusal of a hop is the guest's typed error, and nothing is sent", %{
      context: context,
      edge: edge,
      credentials: credentials
    } do
      url = "http://login.other.test:#{context.port}/session"
      pin = redirected(context, edge, credentials, url)

      assert %{"error" => %{"type" => "redirect_credentials", "message" => message}} =
               fetch(context, edge, url, credentials)

      assert message =~ "login.other.test"

      assert_received {:pinned, %{"purpose" => "redirect", "from" => ^pin},
                       {:error, :redirect_credentials}}

      assert [%{path: "/redirect"}] = context.seen.()
      # The host recorded its refusal; the engine records none of it.
      assert ScriptedHost.requests(context.host, "record_denial") == []
    end

    test "a metadata target on a hop is refused before any request", %{
      context: context,
      edge: edge,
      credentials: credentials
    } do
      url = "http://meta.other.test:#{context.port}/latest"
      pin = redirected(context, edge, credentials, url)

      assert %{"error" => %{"type" => "private_ip_blocked", "message" => message}} =
               fetch(context, edge, url, credentials)

      assert message =~ "metadata IP"
      assert_received {:pinned, %{"purpose" => "redirect", "from" => ^pin}, {:ok, _}}
      assert [%{path: "/redirect"}] = context.seen.()
    end
  end
end
