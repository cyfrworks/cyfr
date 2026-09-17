# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.EgressTest do
  @moduledoc """
  A guest's outbound request connects to the address its host resolved to
  once, checked before the connection: a scheme other than http or https,
  a missing host, a metadata address under any policy, and a private
  address the consent does not admit are each refused; an admitted
  address is pinned as the connection target with the hostname kept for
  TLS and the fail-closed transport policy set.
  """

  use ExUnit.Case, async: true

  alias Opus.Egress

  test "a public address pins with the hostname kept and the transport policy closed" do
    assert {:ok, pinned} = Egress.pin("https://localhost:8443/path?q=1", private_policy: {:fun, fn _ -> true end})
    assert pinned.ip == "127.0.0.1"
    assert pinned.ip_tuple == {127, 0, 0, 1}
    assert pinned.uri.host == "localhost"

    assert pinned.req_opts[:url] == "https://127.0.0.1:8443/path?q=1"
    assert pinned.req_opts[:connect_options][:hostname] == "localhost"
    assert pinned.req_opts[:redirect] == false
    assert pinned.req_opts[:retry] == false
    assert pinned.req_opts[:compressed] == false
    assert pinned.req_opts[:decode_body] == false
    assert pinned.req_opts[:receive_timeout] == 30_000
  end

  test "the caller's protocols, transport options and timeout ride along" do
    assert {:ok, %{req_opts: opts}} =
             Egress.pin("http://localhost/",
               private_policy: {:fun, fn _ -> true end},
               protocols: [:http1],
               transport_opts: [verify: :verify_none],
               receive_timeout: 5
             )

    assert opts[:connect_options][:protocols] == [:http1]
    assert opts[:connect_options][:transport_opts] == [verify: :verify_none]
    assert opts[:receive_timeout] == 5
  end

  test "a private address is refused unless the consent admits it, and a nil policy denies" do
    assert {:error, :private_ip_blocked, message} = Egress.pin("http://127.0.0.1/")
    assert message =~ "private IP 127.0.0.1 blocked"

    assert {:error, :private_ip_blocked, _} =
             Egress.pin("http://127.0.0.1/", private_policy: {:fun, fn _ -> false end})

    assert {:ok, %{ip: "127.0.0.1"}} =
             Egress.pin("http://127.0.0.1/", private_policy: {:fun, fn ip -> ip == {127, 0, 0, 1} end})
  end

  test "a metadata address is refused whatever the policy" do
    for url <- ["http://169.254.169.254/latest", "http://[fd00:ec2::254]/"] do
      assert {:error, :private_ip_blocked, message} =
               Egress.pin(url, private_policy: {:fun, fn _ -> true end})

      assert message =~ "metadata IP"
    end
  end

  test "a scheme other than http or https, and a missing host, are invalid URLs" do
    assert {:error, :invalid_url, "blocked URL scheme: ftp"} = Egress.pin("ftp://example.com/")
    assert {:error, :invalid_url, "missing URL scheme"} = Egress.pin("example.com/path")
    assert {:error, :invalid_url, "missing hostname"} = Egress.pin("http:///path")
  end

  test "a host that does not resolve is a DNS error" do
    assert {:error, :dns_error, message} = Egress.pin("https://nonexistent.invalid/")
    assert message =~ "nonexistent.invalid"
  end

  test "an IPv6 literal is bracketed in the pinned URL" do
    assert {:ok, %{req_opts: opts, ip: "::1"}} =
             Egress.pin("http://[::1]:8080/x", private_policy: {:fun, fn _ -> true end})

    assert opts[:url] == "http://[::1]:8080/x"
  end
end
