# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.NetworkPureTest do
  use ExUnit.Case, async: true

  alias Cyfr.Network

  test "URL parsing refuses invalid destinations without resolution" do
    for {url, message} <- [
          {"//example.test/x", "missing URL scheme"},
          {"file:///etc/passwd", "blocked URL scheme: file"},
          {"https:///x", "missing hostname"}
        ] do
      assert {:error, :invalid_url, ^message} = Network.parse_url(url)
    end
  end

  test "pinning uses the supplied address and retains URL and TLS identity" do
    {:ok, uri} = Network.parse_url("https://example.test:8443/path?q=1")
    ip = {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}

    assert {:ok, %{uri: ^uri, ip_tuple: ^ip, req_opts: opts}} =
             Network.pin(uri, ip,
               receive_timeout: 71,
               protocols: [:http1],
               transport_opts: [verify: :verify_peer]
             )

    assert opts[:url] == "https://[2001:db8::1]:8443/path?q=1"
    assert opts[:connect_options][:hostname] == "example.test"
    assert opts[:connect_options][:protocols] == [:http1]
    assert opts[:connect_options][:transport_opts] == [verify: :verify_peer]

    assert opts[:receive_timeout] == 71

    for option <- [:redirect, :retry, :compressed, :decode_body],
        do: assert(opts[option] == false)
  end

  test "private addresses need an explicit policy and match only explicit targets" do
    {:ok, uri} = Network.parse_url("http://service.internal/")
    ip = {10, 1, 2, 3}
    assert {:error, :private_ip_blocked, _} = Network.pin(uri, ip, [])
    assert {:error, :private_ip_blocked, _} = Network.pin(uri, ip, private_policy: :operator)

    for policy <- [
          :allow_all,
          {:allowlist, ["SERVICE.internal"]},
          {:allowlist, ["10.0.0.0/8"]},
          {:fun, fn address -> address == ip end}
        ] do
      assert {:ok, _} = Network.pin(uri, ip, private_policy: policy)
    end

    refute Network.private_allowed?(uri.host, ip, [])
    refute Network.private_allowed?(uri.host, ip, ["service.internal.evil", "192.168.0.0/16"])
    assert Network.private_allowed?(nil, ip, ["10.1.2.3"])
  end

  test "metadata refusals precede every override, including embedded IPv4" do
    {:ok, uri} = Network.parse_url("https://metadata.test/")

    for literal <- [
          "169.254.169.254",
          "100.100.100.200",
          "fd00:ec2::254",
          "64:ff9b::a9fe:a9fe",
          "2002:a9fe:a9fe::1"
        ] do
      {:ok, ip} = Cyfr.Cidr.parse_ip(literal)

      for policy <- [
            :allow_all,
            {:allowlist, ["metadata.test", "0.0.0.0/0", "::/0"]},
            {:fun, fn _ -> flunk("metadata reached the policy override") end}
          ] do
        assert {:error, :private_ip_blocked, message} =
                 Network.pin(uri, ip, private_policy: policy)

        assert message =~ "metadata IP"
      end
    end
  end
end
