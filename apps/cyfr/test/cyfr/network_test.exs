# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.NetworkTest do
  use ExUnit.Case, async: true

  alias Cyfr.Network

  describe "validate_redirect_url/2" do
    test "allows public HTTPS URLs" do
      # Uses a well-known public hostname that resolves to a public IP
      assert :ok = Network.validate_redirect_url("https://storage.googleapis.com/bucket/blob")
    end

    test "allows public HTTP URLs" do
      assert :ok = Network.validate_redirect_url("http://storage.googleapis.com/bucket/blob")
    end

    test "rejects file:// scheme" do
      assert {:error, "blocked URL scheme: file"} =
               Network.validate_redirect_url("file:///etc/passwd")
    end

    test "rejects ftp:// scheme" do
      assert {:error, "blocked URL scheme: ftp"} =
               Network.validate_redirect_url("ftp://evil.com/file")
    end

    test "rejects missing scheme" do
      assert {:error, "missing URL scheme"} =
               Network.validate_redirect_url("//no-scheme.com/path")
    end

    test "rejects missing hostname" do
      assert {:error, "missing hostname"} =
               Network.validate_redirect_url("https:///path-only")
    end

    test "blocks loopback 127.0.0.1" do
      assert {:error, msg} = Network.validate_redirect_url("http://127.0.0.1/metadata")
      assert msg =~ "private IP"
      assert msg =~ "127.0.0.1"
    end

    test "blocks link-local 169.254.169.254 (cloud metadata)" do
      assert {:error, msg} =
               Network.validate_redirect_url("http://169.254.169.254/latest/meta-data/")

      assert msg =~ "link-local IP"
      assert msg =~ "169.254.169.254"
    end

    test "169.254.x.x always blocked even with private_policy: :allow_all" do
      assert {:error, msg} =
               Network.validate_redirect_url("http://169.254.169.254/latest/meta-data/",
                 private_policy: :allow_all
               )

      assert msg =~ "link-local IP"
    end

    test "private_policy: :allow_all permits 127.0.0.1" do
      assert :ok =
               Network.validate_redirect_url("http://127.0.0.1/v2/", private_policy: :allow_all)
    end

    test "private_policy: :allow_all permits localhost" do
      assert :ok =
               Network.validate_redirect_url("http://localhost/v2/", private_policy: :allow_all)
    end

    test "DNS failure returns error" do
      assert {:error, msg} =
               Network.validate_redirect_url(
                 "https://this-domain-definitely-does-not-exist-xyz123.invalid/path"
               )

      assert msg =~ "DNS resolution failed"
    end
  end

  describe "resolve_and_validate/2" do
    test "returns the validated IP and parsed URI for a public host" do
      assert {:ok, ip, %URI{host: "storage.googleapis.com"}} =
               Network.resolve_and_validate("https://storage.googleapis.com/bucket/blob")

      assert tuple_size(ip) in [4, 8]
      refute Cyfr.Cidr.private_ip?(ip)
    end

    test "blocks a host that resolves to a private IP" do
      assert {:error, msg} = Network.resolve_and_validate("http://127.0.0.1/x")
      assert msg =~ "private IP"
    end

    test "always blocks link-local (cloud metadata) even with private_policy: :allow_all" do
      assert {:error, msg} =
               Network.resolve_and_validate("http://169.254.169.254/", private_policy: :allow_all)

      assert msg =~ "link-local"
    end
  end

  describe "pinned_request/5 SSRF + DNS-rebinding guard" do
    # The security contract: a private/link-local resolution is rejected BEFORE
    # any connection, and the connection (when allowed) targets the validated IP
    # — so there is no second DNS resolution to rebind.
    test "blocks loopback before connecting" do
      assert {:error, msg} = Network.pinned_request(:get, "http://127.0.0.1/")
      assert msg =~ "private IP"
    end

    test "always blocks the link-local metadata endpoint" do
      assert {:error, msg} =
               Network.pinned_request(:get, "http://169.254.169.254/latest/meta-data/",
                 private_policy: :allow_all
               )

      assert msg =~ "link-local"
    end

    test "rejects non-http(s) schemes" do
      assert {:error, msg} = Network.pinned_request(:get, "file:///etc/passwd")
      assert msg =~ "blocked URL scheme"
    end

    test "returns a DNS error for an unresolvable host" do
      assert {:error, msg} =
               Network.pinned_request(:get, "https://nope-xyz-123-cyfr.invalid/")

      assert msg =~ "DNS resolution failed"
    end
  end

  describe "Cyfr.BoundedBody on the pinned transport's Req.Response" do
    test "collects into a Req.Response and halts past the ceiling" do
      collector = Cyfr.BoundedBody.collector(4)

      {:cont, {_req, resp}} = collector.({:data, "1234"}, {:req, %Req.Response{}})
      assert Cyfr.BoundedBody.read(resp, 4) == {:ok, "1234"}

      {:halt, {_req, resp}} = collector.({:data, "5"}, {:req, resp})
      assert Cyfr.BoundedBody.read(resp, 4) == {:error, {:response_too_large, 5, 4}}
    end
  end
end
