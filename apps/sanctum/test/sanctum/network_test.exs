# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.NetworkTest do
  use ExUnit.Case, async: true

  alias Sanctum.Network
  alias Sanctum.Test.Resolver

  # Every name below resolves through the fixture's table, never the
  # network; an address literal needs no lookup, and `localhost` is the
  # hosts file's.
  @resolver [resolver: Resolver]

  describe "validate_redirect_url/2" do
    test "allows an HTTPS URL whose host resolves to a public address" do
      assert :ok = Network.validate_redirect_url("https://public.test/bucket/blob", @resolver)
    end

    test "allows an HTTP URL whose host resolves to a public address" do
      assert :ok = Network.validate_redirect_url("http://public.test/bucket/blob", @resolver)
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

    test "blocks a host that resolves to a private address" do
      assert {:error, msg} = Network.validate_redirect_url("https://private.test/", @resolver)
      assert msg == "private IP 10.0.0.5 blocked (resolved from private.test)"
    end

    test "blocks the cloud metadata address 169.254.169.254" do
      assert {:error, msg} =
               Network.validate_redirect_url("http://169.254.169.254/latest/meta-data/")

      assert msg =~ "metadata IP"
      assert msg =~ "169.254.169.254"
    end

    test "169.254.x.x always blocked even with private_policy: :allow_all" do
      assert {:error, msg} =
               Network.validate_redirect_url("http://169.254.169.254/latest/meta-data/",
                 private_policy: :allow_all
               )

      assert msg =~ "metadata IP"
    end

    test "blocks a host that resolves to the metadata address whatever the policy" do
      assert {:error, msg} =
               Network.validate_redirect_url("http://metadata.test/latest/meta-data/",
                 private_policy: :allow_all,
                 resolver: Resolver
               )

      assert msg == "metadata IP 169.254.169.254 blocked (resolved from metadata.test)"
    end

    test "private_policy: :allow_all permits 127.0.0.1" do
      assert :ok =
               Network.validate_redirect_url("http://127.0.0.1/v2/", private_policy: :allow_all)
    end

    test "private_policy: :allow_all permits localhost" do
      assert :ok =
               Network.validate_redirect_url("http://localhost/v2/", private_policy: :allow_all)
    end

    test "a host that does not resolve is a DNS error" do
      assert {:error, msg} =
               Network.validate_redirect_url("https://nonexistent.test/path", @resolver)

      assert msg == "DNS resolution failed for nonexistent.test: non-existing domain"
    end
  end

  describe "resolve_and_validate/2" do
    test "returns the validated IP and parsed URI for a public host" do
      assert {:ok, {203, 0, 113, 10}, %URI{host: "public.test", path: "/bucket/blob"}} =
               Network.resolve_and_validate("https://public.test/bucket/blob", @resolver)
    end

    test "pins a dual-stack host to its IPv4 address" do
      assert {:ok, {203, 0, 113, 20}, %URI{host: "dual.test"}} =
               Network.resolve_and_validate("https://dual.test/", @resolver)
    end

    test "pins a host with only an IPv6 address to it" do
      assert {:ok, {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 0x30}, %URI{host: "v6only.test"}} =
               Network.resolve_and_validate("https://v6only.test/", @resolver)
    end

    test "blocks a host that resolves to a private IP" do
      assert {:error, msg} = Network.resolve_and_validate("http://127.0.0.1/x")
      assert msg =~ "private IP"
    end

    test "always blocks cloud metadata even with private_policy: :allow_all" do
      assert {:error, msg} =
               Network.resolve_and_validate("http://169.254.169.254/", private_policy: :allow_all)

      assert msg =~ "metadata IP"
    end
  end

  describe "pin/2" do
    test "pins the validated address, bracketed for IPv6, and keeps the hostname for TLS" do
      assert {:ok, %{ip: "2001:db8::30", req_opts: opts}} =
               Network.pin("https://v6only.test:8443/x?q=1", @resolver)

      assert opts[:url] == "https://[2001:db8::30]:8443/x?q=1"
      assert opts[:connect_options][:hostname] == "v6only.test"
      assert opts[:redirect] == false
      assert opts[:retry] == false
    end
  end
end
