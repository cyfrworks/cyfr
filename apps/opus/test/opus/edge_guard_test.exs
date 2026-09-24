# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.EdgeGuardTest do
  @moduledoc """
  `Opus.EdgeGuard` is the runner's one place a concrete egress request is
  matched against the consent edge an execution runs under. Every HTTP host
  handler asks it before touching a domain, a scheme, a method, an IP or a
  byte budget — so a bug here is not a bug in one import, it is the guest
  reaching past its consent in all of them.

  Its own moduledoc makes two promises this file holds it to.

  **Fail-closed.** A `nil` edge (`resources: :none`), a `nil` resource
  group, and an empty allowlist all deny. The failure mode that matters is
  the inverse of a normal one: a mistake here reads as "everything works"
  in every test that grants what it needs, and nothing else would notice.

  **The denial messages are contract.** Components branch on them and
  guests display them, so they are asserted verbatim rather than by shape.
  """

  use ExUnit.Case, async: true

  alias Opus.EdgeGuard
  alias Prima.Authority.Blob.Edge
  alias Prima.Limits

  defp edge(attrs), do: struct!(Edge, attrs)

  defp egress_edge(egress), do: edge(egress: egress)

  defp limits(attrs) do
    struct!(
      Limits,
      Keyword.merge(
        [
          timeout: 30_000,
          max_memory_bytes: 64 * 1024 * 1024,
          max_request_size: 1_000,
          max_response_size: 2_000,
          rate_limit: 60,
          max_concurrent_tasks: 4,
          batch_timeout: 60_000
        ],
        attrs
      )
    )
  end

  # ==========================================================================
  # Fail-closed
  # ==========================================================================

  describe "an edge that grants nothing" do
    test "a nil edge denies every resource it guards" do
      assert Edge.domains(nil) == []
      assert Edge.paths(nil) == []
      assert Edge.actions(nil) == []
      assert Edge.tools(nil) == []

      assert {:error, _} = EdgeGuard.check_domain(nil, "example.com")
      assert {:error, _} = EdgeGuard.check_scheme(nil, "https")
      assert {:error, _} = EdgeGuard.check_method(nil, "GET")
      refute EdgeGuard.allows_private_ip?(nil, {10, 0, 0, 1})
    end

    test "a nil resource group denies as hard as a nil edge" do
      # An edge that authorizes invocation and grants no egress and no
      # storage is representable and normal — it must not read as
      # unrestricted just because the group is absent rather than empty.
      bare = edge(tools: ["component.list"])

      assert Edge.domains(bare) == []
      assert Edge.paths(bare) == []
      assert {:error, _} = EdgeGuard.check_domain(bare, "example.com")
      assert Edge.tools(bare) == ["component.list"]
    end

    test "an empty allowlist denies, and says what was allowed" do
      empty = egress_edge(%{domains: [], methods: [], schemes: [], private_ips: []})

      assert EdgeGuard.check_domain(empty, "example.com") ==
               {:error,
                "Error: Policy violation - domain \"example.com\" not in allowed_domains\n" <>
                  "Allowed: "}

      assert {:error, _} = EdgeGuard.check_scheme(empty, "https")
      assert {:error, _} = EdgeGuard.check_method(empty, "GET")
      refute EdgeGuard.allows_private_ip?(empty, {10, 0, 0, 1})
    end
  end

  # ==========================================================================
  # Domains
  # ==========================================================================

  describe "check_domain/2" do
    test "an exact host matches only itself" do
      e = egress_edge(%{domains: ["api.example.com"], methods: [], schemes: [], private_ips: []})

      assert :ok = EdgeGuard.check_domain(e, "api.example.com")
      assert {:error, _} = EdgeGuard.check_domain(e, "other.example.com")
      assert {:error, _} = EdgeGuard.check_domain(e, "example.com")

      # The suffix must be a real one, not a substring of a longer name:
      # `evil-api.example.com` ends with the pattern's own characters.
      assert {:error, _} = EdgeGuard.check_domain(e, "evil-api.example.com")
    end

    test "\"*.example.com\" is a subdomain wildcard, not a suffix match" do
      e = egress_edge(%{domains: ["*.example.com"], methods: [], schemes: [], private_ips: []})

      assert :ok = EdgeGuard.check_domain(e, "api.example.com")
      assert :ok = EdgeGuard.check_domain(e, "deep.api.example.com")

      # The dot is part of the pattern, so a name that merely ends in the
      # same letters is a different registrable domain and is refused.
      assert {:error, _} = EdgeGuard.check_domain(e, "notexample.com")
      assert {:error, _} = EdgeGuard.check_domain(e, "evilexample.com")

      # The bare apex is not a subdomain of itself.
      assert {:error, _} = EdgeGuard.check_domain(e, "example.com")
    end

    test "\"*\" allows any host" do
      e = egress_edge(%{domains: ["*"], methods: [], schemes: [], private_ips: []})

      assert :ok = EdgeGuard.check_domain(e, "example.com")
      assert :ok = EdgeGuard.check_domain(e, "169.254.169.254")
    end

    test "the denial names the domain and the allowlist" do
      e =
        egress_edge(%{
          domains: ["a.example.com", "b.example.com"],
          methods: [],
          schemes: [],
          private_ips: []
        })

      assert EdgeGuard.check_domain(e, "c.example.com") ==
               {:error,
                "Error: Policy violation - domain \"c.example.com\" not in allowed_domains\n" <>
                  "Allowed: a.example.com, b.example.com"}
    end
  end

  # ==========================================================================
  # Schemes and methods
  # ==========================================================================

  describe "check_scheme/2 and check_method/2" do
    test "a scheme is matched exactly — there is no wildcard value" do
      e = egress_edge(%{domains: [], methods: [], schemes: ["https"], private_ips: []})

      assert :ok = EdgeGuard.check_scheme(e, "https")
      assert {:error, _} = EdgeGuard.check_scheme(e, "http")
      assert {:error, _} = EdgeGuard.check_scheme(e, "file")

      # `"*"` is a domain pattern, not a scheme value: an edge that spelled
      # it here would grant `file:` and `gopher:` if it were honoured.
      assert {:error, _} = EdgeGuard.check_scheme(e, "*")
    end

    test "a method matches case-insensitively, and is reported upcased" do
      e = egress_edge(%{domains: [], methods: ["get", "POST"], schemes: [], private_ips: []})

      assert :ok = EdgeGuard.check_method(e, "GET")
      assert :ok = EdgeGuard.check_method(e, "get")
      assert :ok = EdgeGuard.check_method(e, "post")

      assert EdgeGuard.check_method(e, "delete") ==
               {:error,
                "Error: Policy violation - method \"DELETE\" not in allowed_methods\n" <>
                  "Allowed: get, POST"}
    end
  end

  # ==========================================================================
  # Private IPs
  # ==========================================================================

  describe "allows_private_ip?/2" do
    test "an exact entry matches that address only" do
      e =
        egress_edge(%{
          domains: [],
          methods: [],
          schemes: [],
          private_ips: ["192.168.1.100"]
        })

      assert EdgeGuard.allows_private_ip?(e, {192, 168, 1, 100})
      refute EdgeGuard.allows_private_ip?(e, {192, 168, 1, 101})
    end

    test "a CIDR entry matches its range" do
      e = egress_edge(%{domains: [], methods: [], schemes: [], private_ips: ["10.0.0.0/8"]})

      assert EdgeGuard.allows_private_ip?(e, {10, 0, 0, 1})
      assert EdgeGuard.allows_private_ip?(e, {10, 255, 255, 254})
      refute EdgeGuard.allows_private_ip?(e, {11, 0, 0, 1})
      refute EdgeGuard.allows_private_ip?(e, {192, 168, 1, 1})
    end

    test "cloud metadata is denied however wide the allowlist is" do
      # The address every cloud provider serves instance credentials from.
      # An allowlist that names it, or a `0.0.0.0/0` that swallows it, must
      # not reach it — this is the check that keeps a consented egress to a
      # private range from becoming a credential read.
      for entry <- ["169.254.169.254", "169.254.0.0/16", "0.0.0.0/0"] do
        e = egress_edge(%{domains: [], methods: [], schemes: [], private_ips: [entry]})

        refute EdgeGuard.allows_private_ip?(e, {169, 254, 169, 254}),
               "#{entry} reached cloud metadata"
      end

      wide = egress_edge(%{domains: [], methods: [], schemes: [], private_ips: ["::/0"]})
      refute EdgeGuard.allows_private_ip?(wide, {0xFE80, 0, 0, 0, 0, 0, 0, 1})

      # The metadata address behind NAT64, local-use NAT64 and 6to4.
      for embedded <- [
            {0x64, 0xFF9B, 0, 0, 0, 0, 0xA9FE, 0xA9FE},
            {0x64, 0xFF9B, 1, 0, 0, 0, 0xA9FE, 0xA9FE},
            {0x2002, 0xA9FE, 0xA9FE, 0, 0, 0, 0, 1}
          ] do
        refute EdgeGuard.allows_private_ip?(wide, embedded), inspect(embedded)
      end

      refute EdgeGuard.allows_private_ip?(wide, {0xFD00, 0x0EC2, 0, 0, 0, 0, 0, 0x0254})

      everything =
        egress_edge(%{domains: [], methods: [], schemes: [], private_ips: ["0.0.0.0/0"]})

      refute EdgeGuard.allows_private_ip?(everything, {100, 100, 100, 200})
      refute EdgeGuard.allows_private_ip?(everything, {192, 0, 0, 192})

      assert EdgeGuard.allows_private_ip?(wide, {0x64, 0xFF9B, 0, 0, 0, 0, 0x0A00, 0x0001})
    end
  end

  # ==========================================================================
  # Size ceilings
  # ==========================================================================

  describe "check_envelope_size/2" do
    test "the envelope ceiling is the payload ceiling doubled plus framing" do
      l = limits(max_request_size: 1_000)
      ceiling = 1_000 * 2 + EdgeGuard.envelope_overhead()

      assert :ok = EdgeGuard.check_envelope_size(l, String.duplicate("x", ceiling))

      assert {:error, :request_too_large} =
               EdgeGuard.check_envelope_size(l, String.duplicate("x", ceiling + 1))
    end

    test "a payload at the consented ceiling always fits once base64'd" do
      # The reason the envelope is generous: a request at the limit arrives
      # as ~4/3 its size in base64 plus JSON escaping. A ceiling that
      # refused it would refuse a legitimate consented request.
      l = limits(max_request_size: 1_000)
      encoded = Base.encode64(:crypto.strong_rand_bytes(1_000))

      assert :ok =
               EdgeGuard.check_envelope_size(
                 l,
                 Jason.encode!(%{"body" => encoded, "url" => "https://example.com"})
               )
    end

    test "a limits struct with no numeric ceiling checks nothing" do
      assert :ok = EdgeGuard.check_envelope_size(limits(max_request_size: nil), "anything")
      assert :ok = EdgeGuard.check_envelope_size(limits(max_request_size: 0), "anything")
    end
  end

  describe "check_request_size/2" do
    test "the URL and headers count against the same ceiling as the body" do
      l = limits(max_request_size: 100)

      assert :ok = EdgeGuard.check_request_size(l, %{body: String.duplicate("x", 50), url: ""})

      # Body alone under the limit, but the headers carry it over: measuring
      # the body alone let a guest move megabytes through header values
      # while the consented ceiling read as enforced.
      assert {:error, :request_too_large, message} =
               EdgeGuard.check_request_size(l, %{
                 body: String.duplicate("x", 50),
                 url: "https://example.com/",
                 headers: [{"x-smuggle", String.duplicate("y", 60)}]
               })

      assert message =~ "incl. URL and headers"
    end

    test "a multipart request is measured by its parts plus the metadata" do
      l = limits(max_request_size: 100)

      assert :ok =
               EdgeGuard.check_request_size(l, %{
                 multipart: [%{data: String.duplicate("x", 40)}, %{value: "small"}],
                 url: ""
               })

      assert {:error, :request_too_large, message} =
               EdgeGuard.check_request_size(l, %{
                 multipart: [%{data: String.duplicate("x", 101)}],
                 url: ""
               })

      assert message =~ "Multipart request"
    end

    test "a nil body is zero bytes, not a crash" do
      assert :ok =
               EdgeGuard.check_request_size(limits(max_request_size: 10), %{body: nil, url: ""})
    end
  end

  describe "check_response_size/2 and check_response_bytes/2" do
    test "both arities give the same answer and the same message" do
      l = limits(max_response_size: 100)
      body = String.duplicate("x", 101)

      assert {:error, :response_too_large, message} = EdgeGuard.check_response_size(l, body)
      assert {:error, :response_too_large, ^message} = EdgeGuard.check_response_bytes(l, 101)

      assert message == "Response body (101 bytes) exceeds limit (100 bytes)"
    end

    test "the ceiling itself is allowed; one byte past it is not" do
      l = limits(max_response_size: 100)

      assert :ok = EdgeGuard.check_response_bytes(l, 100)
      assert {:error, :response_too_large, _} = EdgeGuard.check_response_bytes(l, 101)
      assert :ok = EdgeGuard.check_response_size(l, nil)
    end
  end
end
